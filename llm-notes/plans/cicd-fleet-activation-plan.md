# CI/CD Pipeline and Fleet Activation Plan

Plan date: 2026-04-03
Specification: `llm-notes/specs/cicd-fleet-management.md`
Replaces: `llm-notes/plans/ci-cd-plan.md`

> **Refresh note (2026-06-13).** The host map below has been updated for
> liberl/zeiss, the APP/DMZ split, and deployd removal. Sections that discuss
> dynamic workload execution still need implementation-time review against the
> k3s/KubeVirt plans.
>
> **Refresh note (2026-06-15).** Phase 1 is reconciled with the hybrid CI
> architecture decided in
> [`k3s-cluster-workloads-plan.md`](../wip/k3s-cluster-workloads-plan.md):
> `saint-arkh` stays as the Woodpecker server microVM, but build execution moves
> to Woodpecker's Kubernetes backend on erebonia's k3s cluster. The older
> bare-metal Woodpecker-agent + standalone containerd/Kata path is superseded.
>
> **Reconciliation note (2026-06-16).** Keeping the Woodpecker control plane in
> a microVM is a deliberate dependency-boundary choice, not leftover pre-k3s
> inertia. `saint-arkh` provides the stable CI identity, webhook receiver, UI,
> SQLite state, and external config service outside the cluster; k3s provides
> disposable, policy-constrained build execution through the Kubernetes backend.
> If k3s/Flux is degraded, the CI control plane and job history remain reachable
> for diagnosis and repair, even though normal build pods may be unavailable.
>
> **Implementation status (2026-06-16).** First pass for Phase 1.2 is in the
> flake: `saint-arkh` has been repurposed from Forgejo Actions runner to
> control-plane-only Woodpecker server, with a localhost-only configuration
> extension, nginx/TLS endpoint at `woodpecker.internal`, sops-backed Forgejo
> OAuth/agent secret material, and 1 GB RAM. The config extension currently
> emits a minimal flake-backed preflight pipeline that runs
> `./scripts/agent-preflight.sh --quick`. Because the implementation container
> did not have the saint-arkh sops key, the new Woodpecker sops entries are
> temporarily mapped to the existing encrypted `forgejo-runner-token` key so the
> system evaluates; before deployment, create dedicated
> `woodpecker-agent-secret`, `woodpecker-forgejo-client`, and
> `woodpecker-forgejo-secret` values in `secrets.yaml`. Remaining Phase 1 work:
> create the Forgejo OAuth application and secrets, wire the Kubernetes
> Woodpecker agent backend/build namespace through the cluster layer, then
> expand generated CI output to full check summaries and merge gates.
>
> **Implementation status (2026-06-16, second pass).** The Kubernetes backend
> layer is now declared on erebonia: Nix/k3s auto-applies the
> `woodpecker-system` agent namespace, the restricted `woodpecker-builds`
> namespace, RBAC for the Woodpecker Kubernetes backend, a default-deny
> build-namespace NetworkPolicy with explicit DNS/public/creil/zeiss/saint-arkh
> egress, and a single Woodpecker agent Deployment using
> `WOODPECKER_BACKEND=kubernetes`. `saint-arkh` now exposes Woodpecker gRPC on
> port 9000 only to erebonia and the generated pipeline pins the clone and Nix
> step images to k3s-preloaded image names with `runsc`/Restricted-compatible
> backend options. Deployment is still blocked on real secret/image material: create the
> saint-arkh sops values listed above, create the `woodpecker-agent-secret`
> Kubernetes Secret in `woodpecker-system`, validate the generated CI image
> under a real Woodpecker build pod, then create the Forgejo OAuth application.
>
> **Implementation status (2026-06-16, image-management update).** Woodpecker's
> platform images are now managed idiomatically through Nix/k3s rather than as a
> separate registry bootstrap step. The colocated Woodpecker k3s config defines fixed-output
> `dockerTools.pullImage` archives for
> `docker.io/woodpeckerci/woodpecker-agent:v3.15.0` and
> `docker.io/woodpeckerci/plugin-git:2.9.1`, plus a Nix-built
> `localhost/dotfiles-ci-nix:0.1.0` image archive. The image derivations live in
> `hosts/erebonia/k3s/woodpecker-images.nix`, and
> `hosts/erebonia/k3s/woodpecker-ci.nix` registers them with
> `services.k3s.images`, so k3s links the archives from the Nix store into
> `/var/lib/rancher/k3s/agent/images` and imports them before the agent starts.
> The Woodpecker manifests reference those local image names directly;
> `forgejo-registry-pull` is no longer required for the initial Woodpecker
> agent, clone, or preflight build images. Future CI steps that use private
> dynamic images can still add scoped pull secrets later. The custom CI image is
> built with the Nix database and uid/gid 1000 store ownership for the restricted
> non-root build pods, but the first deployment still must validate that
> `nix develop --command ./scripts/agent-preflight.sh --quick` can realize any
> missing dev-shell closure inside the real Woodpecker pod environment.

## Overview

This plan implements the CI/CD pipeline and fleet activation system specified in
`cicd-fleet-management.md`, mapped onto this homelab's concrete hosts and services.
The system has two halves:

1. **CI pipeline** — Woodpecker CI builds NixOS closures, signs them, pushes to
   Attic, and publishes build events to NATS
2. **Fleet activation** — per-host coordinators receive events via NATS, download
   and verify closures, activate via `nixos-rebuild`, and publish results

### Design Principles

- **Coordination layer, not dependency**: CI/CD sits above the infrastructure as
  a convenience layer. Every system it automates (NixOS deploys, OpenWrt image
  builds, dashboard management) remains fully operable via manual commands if the
  pipeline is unavailable or broken. `deploy-rs` or
  `nixos-rebuild switch --target-host` from the operator's workstation always
  works. Higher layers coordinate lower layers, but lower layers operate
  independently.
- **Nix-native first**: The primary artifact is a Nix derivation, not a container
  image. The binary cache is the main distribution mechanism.
- **PR-as-trust-boundary**: AI agents can propose changes freely via PRs. CI
  checks gate mergeability. Humans review and merge. No AI-initiated deploys
  without human approval.
- **Events describe facts, not commands**: The event bus records things that
  happened ("CI built closure X from commit Y"). Coordinators are autonomous
  agents that subscribe to facts and decide how to respond based on local policy.

### Host Mapping

| Spec reference     | Homelab host | Role                                              |
| ------------------ | ------------ | ------------------------------------------------- |
| "router"           | thebeyond    | Router, underpowered, network infrastructure      |
| "NAS"              | liberl       | NAS, ZFS, hosts Attic (zeiss)                     |
| "2021 NUC" / build | erebonia     | k3s/KubeVirt host; schedules Woodpecker build pods |
| "2023 NUC"         | calvard      | Primary VM host, hosts Forgejo (creil)            |
| Forgejo            | creil        | MicroVM on calvard, git forge only                |
| Attic              | zeiss        | MicroVM on liberl, binary cache                   |
| step-ca            | basel        | MicroVM on calvard, TLS certificates              |
| Monitoring         | tharbad      | MicroVM on calvard, Prometheus/VictoriaLogs/Alertmanager |

### Managed Hosts (NATS coordinators)

These hosts receive deployments via the NATS fleet activation system:

| Host      | NixOS configuration | dependsOnActivation | Notes                           |
| --------- | ------------------- | ------------------- | ------------------------------- |
| liberl    | liberl              | null (first)        | NAS — hosts Attic, goes first   |
| calvard   | calvard             | liberl              | Primary VM host                 |
| erebonia  | erebonia            | calvard             | Build server — agent drain last |

Deployment order: `liberl → calvard → erebonia` (strictly sequential,
results-gated).

**Why this order:**

- **liberl first** — hosts Attic (zeiss). Must be confirmed stable before
  other hosts attempt pre-download of closures.
- **calvard second** — general VM host. Activating while liberl (Attic)
  and erebonia (2 of 3 NATS nodes still up) are stable.
- **erebonia last** — hosts k3s/KubeVirt and Woodpecker build pods. Let it finish publishing
  all deployment events before it reboots itself.
- **NATS quorum preserved** — only 1 of 3 NATS hosts is down at any time.
- **Attic availability preserved** — liberl is stable before anyone else
  needs to download closures.

**Future:** When thebeyond gets new hardware and joins the fleet, it slots
in at the front: `thebeyond → liberl → calvard → erebonia`. thebeyond
is the router — if its activation breaks networking, we catch that before
touching anything else. thebeyond also gets a NATS microVM at that point
(expanding the cluster to include the router).

### Hosts NOT Yet Managed by NATS

| Host      | Deployment method  | Reason                                        |
| --------- | ------------------ | --------------------------------------------- |
| thebeyond | deploy-rs / manual | No hardware yet; joins fleet first when ready |
| angbar    | deploy-rs / manual | Workstation, intermittent                     |
| kernviter | deploy-rs / manual | Laptop, intermittent                          |
| OpenWrt   | `openwrt-deploy`   | Not NixOS                                     |

### What Already Exists

| Component                    | State                                 | Location                      |
| ---------------------------- | ------------------------------------- | ----------------------------- |
| Forgejo (creil)              | Deployed                              | calvard, APP (10.97.50.53)    |
| Attic (zeiss)                | Deployed, 3-min GC (needs adjustment) | liberl, APP (10.97.50.31)     |
| Woodpecker server (saint-arkh) | First-pass NixOS config added; OAuth secrets and k8s agent backend still pending | erebonia, APP (10.97.50.61)   |
| step-ca (basel)              | Deployed                              | calvard, INFRA (10.97.11.7)   |
| Monitoring (tharbad)         | Deployed                              | calvard, MGMT (10.97.20.41)   |
| deploy-rs                    | thebeyond only                        | flake.nix                     |
| Nested KVM on erebonia       | Enabled                               | hosts/erebonia/default.nix    |
| k3s + KubeVirt               | Deployed on erebonia                  | hosts/erebonia/k3s/           |

---

## Phase 1: Woodpecker CI on erebonia

**Goal:** Replace Forgejo Actions with Woodpecker CI. saint-arkh becomes the
Woodpecker server microVM. Woodpecker build execution uses the **Kubernetes backend**:
per-step pods run on erebonia's k3s cluster with RuntimeClass/PSS/NetworkPolicy
hardening. This supersedes the older bare-metal Woodpecker-agent +
standalone-containerd/Kata design.

**Prerequisites:** None — builds on existing infrastructure.

### 1.1 Make creil the primary repo, mirror to GitHub

Forgejo on creil is the primary remote for the dotfiles repo. GitHub becomes
a push mirror. This ensures Woodpecker receives push/PR/merge webhook events
directly from the primary.

- Configure the dotfiles repo on creil as the primary origin
- Set up a push mirror to GitHub (Forgejo supports this natively via
  repository settings → Mirror Settings)
- Update local developer remotes to point to creil
- Verify webhook delivery to Woodpecker on push

### 1.2 Repurpose saint-arkh as Woodpecker server

Replace the Forgejo Actions runner configuration in saint-arkh with the
Woodpecker server + the External Configuration Service (config service). Do
not run a standing Woodpecker agent in the microVM; `saint-arkh` is the stable
control plane and identity, while k3s runs the per-step build pods.

Current config: `hosts/erebonia/microvm/guests/saint-arkh/`

- Remove the Forgejo runner module (`modules/runner.nix`)
- Add Woodpecker server service
- Add the config service (localhost-only, co-located with server)
- Woodpecker server connects to creil (Forgejo) via OAuth2 application for
  authentication and webhook events
- Config service generates pipelines from flake outputs — the flake is the
  single source of truth for both system configuration and CI pipeline definition

### 1.2a Why the Woodpecker server stays outside k3s

Running the Woodpecker server itself as a Flux-managed workload would integrate
well with Kubernetes RBAC, NetworkPolicy, Services, and the same GitOps
ownership model used by other dynamic workloads. That path is still viable if
the CI control plane later needs to become just another cluster service.

For the initial fleet CI system, the microVM boundary is a better dependency
shape:

- **Stable identity and state.** `saint-arkh` keeps a normal host identity,
  SSH access, logs, metrics, persistent SQLite state, and a durable webhook
  endpoint independent of in-cluster ingress and PVC readiness.
- **Repair path.** A broken k3s/Flux layer can stop new build pods, but it does
  not also remove the CI UI, job metadata, webhook receiver, or config service.
  The operator can inspect CI state and repair the cluster from outside it.
- **Clear trust split.** The server/config service is trusted coordination
  state. Build steps are untrusted execution and belong in the constrained
  `woodpecker-builds` namespace with RuntimeClass/PSS/NetworkPolicy/Kyverno.
- **No CSI prerequisite.** The server's SQLite database can remain on the
  microVM persist volume. Putting it in k3s would force PVC/CSI/storage
  decisions before the CI control plane can exist.

The tradeoff is that `saint-arkh` remains one small NixOS guest to deploy and
monitor. That is acceptable because the runner workload moves out of the guest;
the microVM is control-plane-only.

### 1.2b MicroVM sizing

Current repo state has `saint-arkh` at **1 vCPU / 512 MB RAM / 25 GB persist**
while it runs the Forgejo Actions runner. The historical 4 vCPU / 4 GB note was
runner-era capacity planning and no longer applies once builds move to k3s.

Recommended initial Woodpecker-server size:

- **1 vCPU** — enough for the Go web service, webhook handling, SQLite, and the
  small external config service. Build CPU is consumed by k3s pods, not this VM.
- **1 GB RAM** — a conservative bump from the current 512 MB to leave headroom
  for NixOS baseline services, Woodpecker, config generation, journald, metrics,
  and short UI/API bursts. Start here rather than 2 GB; increase only if real
  RSS/oomd pressure appears.
- **25 GB persist** — retain the existing volume. SQLite, logs, and config
  service state are small, but keeping the current disk avoids migration churn
  and leaves enough history headroom.

Do not size `saint-arkh` for Nix builds, container pulls, or VM tests. Those
belong to the Kubernetes backend's pod resource requests/limits and any later
trusted KVM-capable build class.

**Evaluate `woodpecker-flake-pipeliner` (pinpox):** If incompatible with
current Woodpecker version or abandoned, a replacement config service is
~200-300 lines and bounded.

### 1.3 Configure Woodpecker Kubernetes backend on erebonia

erebonia already has k3s/KubeVirt and nested KVM enabled. Build execution should
use Woodpecker's Kubernetes backend rather than a host-level Woodpecker agent:

- Configure `WOODPECKER_BACKEND=kubernetes` on the Woodpecker agent deployment
  that connects to the saint-arkh server.
- Create the build namespace, service account/RBAC, and backend configuration
  through the Flux-managed dynamic layer once the Flux `GitRepository` +
  `Kustomization` path is wired.
- Use the k3s runtime tiers already present on erebonia: gVisor (`runsc`) for
  ordinary untrusted build steps; opt-in stronger runtimes only where the
  workload has been validated.
- Keep `/dev/kvm` / nested NixOS VM tests as a separately validated build class.
  Do not assume every build pod should get KVM access.
- Keep an operator/out-of-cluster repair path so a broken k3s cluster is not the
  only way to produce its own fix.

### 1.4 Define build pod hardening

The build namespace is the untrusted-code boundary. It should use the security
stack from `llm-notes/wip/k3s-cluster-workloads-plan.md` Phase 4:

- PSS Restricted where compatible with the required build jobs.
- RuntimeClass defaulting to gVisor (`runsc`) for ordinary steps.
- NetworkPolicy default-deny with explicit egress to Forgejo/creil, Attic/zeiss,
  DNS, and any required public fetch paths.
- Kyverno policies for resource limits and admission guardrails.
- Secrets scoped to the build namespace and service account, not host-level
  agent secrets on erebonia.

### 1.5 Create Forgejo OAuth2 application for Woodpecker

On creil (Forgejo), create an OAuth2 application that Woodpecker uses for:

- User authentication (login to Woodpecker UI)
- Webhook registration (push/PR/merge events trigger builds)
- Repository access (checkout code)

Store the OAuth2 client secret in sops on saint-arkh.

### 1.6 Create initial CI workflow

With the config service generating pipelines from flake outputs, the initial
pipeline builds all `checks.x86_64-linux.*` targets.

The config service introspects the flake and generates a Woodpecker pipeline
that:

- Checks out the repo
- Runs `nix build .#checks.x86_64-linux.<name>` for each check
- Reports results back to Forgejo
- Emits a machine-readable check summary artifact and a compact PR-facing
  summary (`check-summary.json` and `check-summary.md`). Each failed check
  should include the check name, exact reproduction command, failing command,
  relevant log tail, and a pointer to the full log/artifact. Agents should not
  need to scrape large CI logs to find the actionable failure.

### 1.6a Agent PR feedback integration

The CI gap is not only "run checks on PRs"; it is "make PR state and check
failures readable by an LLM with narrow credentials." Add a small
Forgejo/Woodpecker-facing tool or MCP server for agent use. Required
capabilities:

- Resolve the current PR from the checked-out branch, AGit topic, or head SHA.
- Read PR description, lifecycle comments, review comments, requested changes,
  and current mergeability/check state.
- Read the compact CI artifacts/comments from 1.6, and fetch full logs only
  when needed.
- Post status comments or answers as the bot, using a token separate from the
  per-session Git push SSH key.
- Surface lifecycle comments such as `agent: retry checks`, `agent: fix review
  comments`, `agent: rebase`, `agent: explain failure`,
  `agent: run full preflight`, and `agent: ready for review`.
- Notify an active agent session when a relevant lifecycle comment or failed
  check appears. The notification channel can start as polling from the agent
  tool; webhook-to-queue delivery can come later.

Keep token scope narrow: read PRs/checks/comments plus write comments/status
only. Do not reuse the Git push credential for API operations, and do not grant
deploy/admin rights to the agent tool.

### 1.6b Required checks and merge gates

Branch protection should require the relevant CI checks before merge. CI should
not be merely advisory: the trust boundary is "agent proposes, CI verifies,
human reviews, protected branch accepts only passing checked changes."

No `.forgejo/workflows/` or `.woodpecker.yml` files needed — the config
service generates pipelines dynamically.

### 1.7 Verify KVM access for VM integration tests

NixOS VM tests (`testers.nixosTest`) need `/dev/kvm`. erebonia already has
`nested=1`, but the Kubernetes backend still needs a deliberate KVM-capable
build class if VM tests run inside cluster pods.

Options to validate before enabling broad VM-test CI:

- a dedicated trusted build pod profile with `/dev/kvm` passed through;
- running VM-heavy checks through an operator/out-of-cluster path while ordinary
  checks run in k8s;
- splitting pure/eval checks from VM integration checks so the k8s backend can
  start useful work before KVM jobs are fully solved.

### 1.8 Resource tuning

erebonia hosts saint-arkh (Woodpecker server), k3s/KubeVirt workloads,
Woodpecker build pods, and Incus guests (trista). Evaluate whether erebonia has
sufficient RAM for sequential `nix build` of check targets in Kubernetes pods.
Do not infer this from the `saint-arkh` microVM size; the microVM is
control-plane-only.

`run-checks.sh -j1` is the baseline. If erebonia can handle `-j2` or higher,
document the safe parallelism level.

### 1.9 Egress rules

Saint-arkh (Woodpecker server) needs:

- creil TCP 443 (Forgejo OAuth2, webhooks, repo access)
- tharbad TCP 3100 (VictoriaLogs Loki-compatible log push — already configured)
- Gateway UDP 53, TCP 53 (DNS — already configured)

Erebonia/k3s build pods need:

- Gateway TCP 80/443 (nix substitution from cache.nixos.org, container pulls)
- Already has management zone access for these

### Network changes

| Change                                   | Where                      |
| ---------------------------------------- | -------------------------- |
| Remove Forgejo runner config             | saint-arkh modules         |
| Add Woodpecker server config             | saint-arkh modules         |
| Add Woodpecker Kubernetes backend RBAC/runtime policy | Flux-managed cluster manifests |
| Forgejo OAuth2 app                       | creil (manual or via API)  |

---

## Phase 2: Attic binary cache integration

**Goal:** CI pushes build artifacts to Attic (zeiss). All managed hosts
substitute from Attic.

**Prerequisites:** Phase 1 (Woodpecker running builds).

> **Attic maintenance risk:** Attic (zhaofengli/attic) is a single-maintainer
> project with a burst-then-quiet development pattern. The risk is not
> abandonment but unpredictable cadence — if a bug blocks us, we may need to
> patch locally. Attic's feature set (chunked deduplication, S3 backend, GC) is
> ahead of alternatives (Harmonia, nix-serve), and the codebase is small enough
> to fork if needed. Phase 5 (Garage) decouples storage, further reducing risk.

### 2.1 Adjust Attic retention

zeiss currently has a 3-minute GC retention period. Change to 30 days per
the spec — this covers hosts offline for weekends, holidays, or short
maintenance windows.

Config: `hosts/liberl/microvm/guests/zeiss/attic.nix`

### 2.2 Create Attic cache and CI push token

- Create a cache named `homelab` on zeiss
- Generate a push token for CI build pods
- Store the token as a sops-backed Kubernetes secret in the build namespace
  (not in Woodpecker's DB)
- The build pod environment is populated from that scoped secret

### 2.3 Add build namespace → zeiss egress rule

Woodpecker build pods on erebonia need to reach `attic.zeiss.internal`
(HTTPS/443) to push build artifacts.

Plain k3s pods currently egress as erebonia's management address (VLAN 11)
until the workload-network plan's flannel-egress redirect lands; zeiss is in APP
(VLAN 50, BT8-gateway-owned). Add the specific management → APP path through
the current BT8-gateway/thebeyond routing model as needed, plus a NetworkPolicy
egress allow from the build namespace to zeiss.

Also add `zeiss` to erebonia's `networking.extraHosts` if not already
resolvable via DNS.

### 2.4 Add Attic push to CI pipeline

After successful `nix build`, the pipeline signs and pushes the closure:

```
nix store sign --key-file $CI_KEY --recursive ./result
attic push homelab ./result
```

The `woodpecker-plugin-nix-attic` plugin handles the Attic push. The CI
signing key is a scoped Kubernetes Secret in the `woodpecker-builds` namespace,
mounted or injected only into build pods that need to sign closures.

Push the **complete closure** — use `nix path-info --recursive` to enumerate
all paths.

### 2.5 Configure all managed hosts to substitute from Attic

Add to `modules/common/` (or a new common module):

```nix
nix.settings = {
  substituters = [ "https://attic.zeiss.internal" ];
  trusted-public-keys = [ "<attic-cache-public-key>" "<ci-public-key>" ];
};
```

The Attic public key can be stored in `lib/common/data/` as a non-secret.
Every NixOS host in the flake benefits from cached builds.

### 2.6 Generate CI signing keypair

Generate an Ed25519 keypair for CI signing:

- Private key: sops secret on erebonia, decrypted to tmpfs
- Public key: committed to `lib/common/data/` for all hosts to trust

This is separate from the Attic signing key (which Attic manages server-side).

### Network changes

| Change                               | Where                      |
| ------------------------------------ | -------------------------- |
| erebonia → zeiss:443 forward rule   | thebeyond router config    |
| erebonia egress → zeiss:443         | hosts/erebonia/default.nix |
| Attic substituter on all hosts       | modules/common/            |
| CI public key in trusted-public-keys | modules/common/            |

---

## Phase 3: NATS JetStream cluster

**Goal:** Deploy a three-node NATS JetStream cluster as the event bus for
fleet activation.

**Prerequisites:** Phase 2 (Attic integration working — closures are built,
signed, and cached).

### 3.1 Create NATS NixOS module

Write a NixOS module for NATS JetStream nodes. This is a top-level module
(`modules/nats/`) since it's extractable infrastructure, not project-specific.

Configuration:

- TLS mandatory (step-ca certificates, 30-day lifetime, 50% renewal)
- WebSockets disabled (no browser clients; CVE-2026-27571 mitigation)
- NKey authentication with JWT-based authorisation
- JetStream enabled with persistent storage

### 3.2 Deploy three NATS microVMs

One microVM per infrastructure host, each allocated **1 vCPU / 128MB RAM /
512MB disk**:

| NATS node | Parent host | Zone       | IP  | Notes                        |
| --------- | ----------- | ---------- | --- | ---------------------------- |
| TBD-name  | liberl   | management | TBD | Co-located with Attic host   |
| TBD-name  | erebonia    | management | TBD | Co-located with build server |
| TBD-name  | calvard     | management | TBD | General infrastructure       |

Names should follow the Trails naming convention for their respective hosts
(liberl = Crossbell cities, erebonia = Erebonian cities, calvard =
Calvard cities).

Network registry entries needed in `lib/common/data/network.nix`.

### 3.3 Configure JetStream streams

- `builds.nixos.*`: retention `LastPerSubject` — each subject retains only
  the most recent build event
- `activations.*`: retention `Limits` with 7-day window — activation results
  for debugging

Consumer configuration: `DeliverLastPerSubjectPolicy` — on connect, receive
the most recent build event, then subsequent events.

### 3.4 Configure NKey permissions

Per-client subject permissions:

- **CI credentials** (erebonia/agent): publish to `builds.>`, subscribe to
  `activations.>`
- **Host credentials** (per managed host): subscribe to
  `builds.nixos.<configuration>` only, publish to `activations.<hostname>` only
- No host can publish to `builds.>`

NKey credentials distributed via sops-nix on each host.

### 3.5 TLS with step-ca

Each NATS microVM gets TLS certificates from basel (step-ca) via ACME.
Certificates cached on persistent disk — if step-ca is temporarily unavailable,
the node continues operating with its cached certificate.

Egress rules needed: each NATS microVM → basel:443 (ACME).

### 3.6 Cross-node cluster routes

The three NATS nodes need to reach each other for Raft consensus:

- Cluster port (default 6222) between all three nodes
- Client port (4222) from managed hosts to all three nodes

Firewall rules needed on thebeyond for intra-management-zone traffic on these
ports (management zone hosts already have some cross-host access).

### 3.7 NATS observability

- `prometheus-nats-exporter` with `-jsz=all` for JetStream metrics
- Scrape target added to tharbad's Prometheus configuration
- Alert rule for cluster health (quorum loss)

### Network changes

| Change                                   | Where                       |
| ---------------------------------------- | --------------------------- |
| 3 NATS microVM configs                   | hosts/{rem,ere,cal}/guests/ |
| Network registry entries for NATS nodes  | lib/common/data/network.nix |
| NATS node → NATS node cluster routes     | thebeyond router config     |
| Managed hosts → NATS nodes client access | thebeyond router config     |
| NATS nodes → basel:443 (ACME)            | egress rules per node       |
| Prometheus scrape targets                | tharbad config              |

---

## Phase 4: Per-host coordinator

**Goal:** Deploy the fleet activation coordinator on all managed hosts.
Receive build events, download and verify closures, activate via
`nixos-rebuild`, publish results.

**Prerequisites:** Phase 3 (NATS cluster running).

### 4.1 Write the coordinator daemon

A systemd service written in Rust using `async-nats`. Target: ~300-500 lines
of application logic.

#### Persistent state

The coordinator maintains two pieces of persistent state in
`/persist/fleet-activation/`:

- **`known-good`** — a Nix GC root symlink
  (`/nix/var/nix/gcroots/fleet-known-good` → `/nix/store/<hash>-nixos-system-...`)
  pointing to the last successful production activation's system closure.
  This is the rollback target for all failure and revert scenarios. Because
  it is a GC root, the known-good closure is protected from garbage
  collection regardless of profile cleanup, `--delete-older-than`, or any
  other GC policy. Updated atomically via `nix-store --add-root` after each
  successful production activation.
- **`last-event`** — a small file containing the `store_path` + `source_ref`
  of the last event the coordinator acted on. Used for deduplication on
  restart. Updated atomically (write-tmp + rename) after each event is
  processed.

The GC root symlink replaces generation number tracking — the symlink _is_
the known-good reference, and it doubles as GC protection. Rollback is
`<known-good-symlink>/bin/switch-to-configuration switch` directly from the
symlink target, with no generation lookup needed.

#### Bootstrap

On first start, if the GC root symlink does not exist, the coordinator
initializes it from the currently running system:

```
if not exists /nix/var/nix/gcroots/fleet-known-good:
  current = readlink /run/current-system
  nix-store --add-root /nix/var/nix/gcroots/fleet-known-good --indirect -r $current
```

This ensures there is always a known-good rollback target, even before the
first CI-driven activation. The first production activation then updates the
symlink normally.

#### Production activation flow

```
receive builds.nixos.<configuration> event where source_ref matches productionRefs
  │
  ├── deduplicate: if store_path + source_ref == lastProcessedEvent, skip
  │
  ├── validate message (timestamp not stale, store path format valid)
  │
  ├── [if test timer is running]: cancel timer (production supersedes test)
  │
  ├── [if dependsOnActivation is set]
  │     wait for upstream host's activation result
  │     if timeout: proceed independently, log warning
  │
  ├── nix copy --from attic <store_path> (pre-download entire closure)
  │
  ├── nix store verify --recursive --sigs-needed 2 <store_path>
  │
  ├── nix-env --profile /nix/var/nix/profiles/system --set <store_path>
  ├── <store_path>/bin/switch-to-configuration switch
  │
  ├── if switch-to-configuration fails (non-zero exit):
  │     <known-good-symlink>/bin/switch-to-configuration switch
  │     nix-env --profile /nix/var/nix/profiles/system --set <known-good-store-path>
  │     publish activations.<hostname> { status: "rolled-back", reason: "activation-failed" }
  │     exit
  │
  ├── [if connectivityCheck.enable]
  │     if connectivity fails:
  │       <known-good-symlink>/bin/switch-to-configuration switch
  │       nix-env --profile /nix/var/nix/profiles/system --set <known-good-store-path>
  │       publish activations.<hostname> { status: "rolled-back", reason: "connectivity-failed" }
  │       exit
  │
  ├── update state:
  │     nix-store --add-root /nix/var/nix/gcroots/fleet-known-good --indirect -r <store_path>
  │     write lastProcessedEvent = this event
  │
  └── publish activations.<hostname> { status: "success", source_ref, store_path }
```

**Activation uses store paths directly, not `nixos-rebuild`.** The coordinator
receives an exact store path from the NATS event, pre-downloads and verifies
it, then activates it via `switch-to-configuration`. This avoids re-evaluating
the flake on the target host (which would require the flake source to be
checked out locally and might produce a different result if main has moved).
The `flake_ref` in the event is audit metadata, not the activation mechanism.
This is the same approach deploy-rs uses.

#### Test activation flow

```
receive builds.nixos.<configuration> event where source_ref matches testRefPatterns
  │
  ├── deduplicate: if store_path + source_ref == lastProcessedEvent, skip
  │
  ├── [if test timer is already running from a previous test]:
  │     cancel existing timer (new test supersedes old test)
  │     revert target remains the known-good symlink (unchanged)
  │
  ├── [same pre-download, dependency wait, and verification steps as production]
  │
  ├── <store_path>/bin/switch-to-configuration test
  │
  ├── if switch-to-configuration test fails (non-zero exit):
  │     <known-good-symlink>/bin/switch-to-configuration switch
  │     publish activations.<hostname> { status: "rolled-back", reason: "test-activation-failed" }
  │     exit
  │
  ├── [if connectivityCheck.enable]
  │     if connectivity fails:
  │       <known-good-symlink>/bin/switch-to-configuration switch
  │       publish activations.<hostname> { status: "rolled-back", reason: "connectivity-failed" }
  │       exit
  │
  ├── start revert timer (testWindowSeconds)
  │     update state: lastProcessedEvent = this event
  │     publish activations.<hostname> { status: "testing", source_ref, store_path }
  │
  ├── [wait for timer or production event]
  │
  ├── on production event:
  │     cancel timer, run production activation flow for the new event
  │
  └── on timer expiry:
        <known-good-symlink>/bin/switch-to-configuration switch
        publish activations.<hostname> { status: "reverted", reason: "test-window-expired" }
```

**Key properties of this design:**

- **Rollback always targets known-good.** Every failure and revert path uses
  the GC root symlink (`fleet-known-good`), not `--rollback` (which goes to
  the previous generation — wrong if multiple tests have stacked). After
  P → T1 → T2, a T2 failure reverts to P, not T1. The symlink is both the
  rollback reference and the GC protection — one mechanism, two purposes.

- **Consecutive tests are handled.** A new test cancels the existing test
  timer and starts fresh. The revert target is always the known-good symlink
  regardless of how many tests have stacked.

- **Timer expiry uses switch, not reboot.** `switch-to-configuration switch`
  on the known-good closure is less disruptive than `systemctl reboot` and
  more predictable — the coordinator stays running and can immediately
  process new events.

- **No re-activation loop after revert.** `last-event` deduplication
  prevents the coordinator from re-processing the same event on restart or
  after reverting. The coordinator sees the `LastPerSubject` event on
  reconnect, matches it against `last-event`, and skips it.

- **Production supersedes test.** A production event arriving during a test
  window cancels the timer and runs the full production flow. If the
  production event's store_path matches the test, the profile update and
  `switch-to-configuration switch` are effectively a no-op (same closure,
  just updates the profile and bootloader).

### 4.2 Create the coordinator NixOS module

Top-level module at `modules/fleet-activation/`. Module interface per the spec:

```nix
services.fleetActivation = {
  enable = true;
  nats.servers = [ ... ];         # all three cluster nodes
  nats.credentialsFile = ...;     # sops-nix NKey credentials
  configuration = "liberl";   # NixOS configuration name
  productionRefs = [ "refs/heads/main" ];
  testRefPatterns = [ "refs/pull/*" ];
  substituters = [ "https://attic.zeiss.internal/homelab" ];
  preDownload = true;
  dependsOnActivation = null;     # set by common module
  connectivityCheck = { enable = true; target = "1.1.1.1"; };

  # Persistent state directory for GC root symlink and event
  # deduplication. Must survive reboots.
  stateDirectory = "/persist/fleet-activation";
  # GC root path — symlink to the known-good closure
  gcRootPath = "/nix/var/nix/gcroots/fleet-known-good";

  # Test window duration before automatic revert to known-good
  testWindowSeconds = 900;  # 15 minutes
};
```

#### Coordinator self-update safety

The coordinator service must use `restartIfChanged = false`. During
activation, `switch-to-configuration` may try to restart the coordinator
if its binary changed — but the coordinator is the process _performing_
the activation. It still needs to publish the result event and update
the GC root after the switch completes.

With `restartIfChanged = false`, the old coordinator binary continues
running from its old store path, finishes its work, and the new binary
takes over on the next reboot or manual restart. This applies to the
coordinator on every managed host, not just erebonia.

#### Pre-download retry logic

The coordinator's pre-download step (`nix copy --from <attic-url>
<store_path>`) should retry with exponential backoff on transient
failures. This is particularly important for calvard and erebonia:
when liberl activates (first in the deployment order), its microVM
guests — including zeiss (Attic) — restart as part of the NixOS
activation. The coordinator publishes "success" once
`switch-to-configuration` returns, but Attic may still be restarting
when the next host begins its pre-download.

A retry window of 2-3 minutes with backoff is sufficient to cover
microVM restart time. If retries are exhausted, the coordinator
publishes a failure event and the deploy phase aborts.

#### Nix GC interaction

The `fleet-known-good` GC root symlink ensures the known-good closure
survives garbage collection regardless of GC policy. The module can
safely allow `nix.gc.automatic = true` with a reasonable
`--delete-older-than` policy — the GC root protects the one closure that
matters, and everything else can be cleaned up normally.

Test activations create system profile generations that accumulate over
time. The coordinator should clean up old test generations after a
successful production activation — delete all generations between the
previous known-good and the new one, since those were intermediate test
states that are no longer needed. Once their profile entries are removed,
normal GC reclaims the store paths.

### 4.3 Add fleet topology to the common module

Declare the deployment topology in `modules/common/`:

```nix
fleetTopology = {
  deploymentOrder = [
    # thebeyond is not yet managed — no hardware for NATS/coordinator.
    # When it joins, it slots in first: thebeyond → liberl → ...
    { host = "liberl"; dependsOn = null; }
    { host = "calvard";   dependsOn = "liberl"; }
    { host = "erebonia";  dependsOn = "calvard"; }
  ];
  dependencyTimeoutSeconds = 600;  # 10 minutes
};
```

**Order rationale:**

- **liberl first** — hosts Attic (zeiss). Must be confirmed stable
  before other hosts attempt to pre-download closures from the cache.
- **calvard second** — general VM host. Activates while Attic (liberl)
  is stable and 2 of 3 NATS nodes are still up.
- **erebonia last** — hosts k3s/KubeVirt, Woodpecker build pods, and CI signing material. Lets
  it finish publishing all deployment events before it reboots itself.
- At each step, only 1 of 3 NATS nodes is potentially down, preserving
  Raft quorum.

Each host's coordinator config is derived from this map.

### 4.4 Deploy coordinator on liberl first

liberl is the first validation target since it leads the deployment order
and hosts Attic:

- Network-safe activation (pre-download mandatory)
- Connectivity check (revert if network unreachable after switch)
- No upstream dependency (first in current topology)

Validate end-to-end: merge to main → CI builds → NATS event → liberl
downloads closure → verifies dual signatures → switches → publishes success.

### 4.5 Deploy coordinator on remaining hosts

After liberl is validated:

- calvard (dependsOn: liberl)
- erebonia (dependsOn: calvard)

For erebonia specifically: there is no host-level Woodpecker agent in the
current hybrid design. erebonia still goes last because it hosts the k3s build
substrate and can disrupt in-flight build pods during activation.

### 4.6 Verify source_ref patterns

**Critical:** Forgejo's PR ref format must be verified against a real PR
before the coordinator goes live. If `testRefPatterns` doesn't match
Forgejo's actual ref format, a PR build could activate with
`nixos-rebuild switch` instead of `nixos-rebuild test` — a permanent
activation from an unreviewed branch.

Expected: `refs/pull/*/head` — confirm against creil.

### 4.7 Add CI deploy phase

After builds complete (parallel), the CI pipeline publishes deployment events
sequentially, gated on each host confirming success:

```
build phase (parallel):
  [liberl] [calvard] [erebonia]

deploy phase (sequential, order from common module):
  nats pub builds.nixos.liberl "$PAYLOAD"
    → nats sub --count 1 activations.liberl
    → if rolled-back or timeout: abort, alert
  nats pub builds.nixos.calvard "$PAYLOAD"
    → nats sub --count 1 activations.calvard
    → if rolled-back or timeout: abort, alert
  nats pub builds.nixos.erebonia "$PAYLOAD"
    → nats sub --count 1 activations.erebonia
    → if rolled-back or timeout: abort, alert
```

CI's NATS NKey credential is a sops secret on erebonia.

### 4.8 Host NATS egress rules

Each managed host needs outbound access to the NATS cluster (port 4222) on
all three NATS nodes. All three infrastructure hosts (liberl, calvard,
erebonia) are in the management zone, so intra-zone routing covers this.

### Network changes

| Change                            | Where                     |
| --------------------------------- | ------------------------- |
| Coordinator module                | modules/fleet-activation/ |
| Fleet topology in common module   | modules/common/           |
| Per-host coordinator config       | hosts/\*/default.nix      |
| NATS NKey credentials per host    | hosts/\*/secrets/         |
| Managed hosts → NATS nodes egress | per-host egress rules     |

---

## Phase 5: Garage S3-compatible storage

**Goal:** Deploy Garage as the S3-compatible storage backend for Attic.
VictoriaLogs storage on tharbad is not migrated here unless a future capacity
review creates a concrete need.

**Prerequisites:** Phase 2 (Attic working). Independent of Phases 3-4.

### 5.1 Evaluate Garage resource requirements

Single-node Garage on liberl (the NAS with ZFS). Estimate storage:

- Attic NAR chunks (primary use case — deduplicated)
- Budget for 6-12 months of growth

### 5.2 Deploy Garage

Garage as a microVM on liberl (or directly on liberl). The S3 API
endpoint needs TLS via step-ca.

Network registry entry needed. Trails naming convention (Crossbell city).

### 5.3 Migrate Attic to S3 backend

Reconfigure zeiss's Attic to use Garage for chunk storage. Attic supports
S3 backends natively. This decouples Attic's cache storage from zeiss's
25GB persist volume — storage lives on liberl's ZFS pool.

### 5.4 VictoriaLogs storage review

VictoriaLogs replaced Loki on tharbad. Leave it on local storage unless a
capacity review shows that S3-backed storage is worth the added moving parts.

### 5.5 Cross-zone networking

Firewall rules for:

- DMZ → Garage (zeiss/Attic needs to reach Garage)
- Management → Garage only if a future tharbad storage review requires it

If Garage is on liberl directly (management zone), the paths are
management-internal or DMZ → management.

### Network changes

| Change                              | Where                       |
| ----------------------------------- | --------------------------- |
| Garage microVM or service           | hosts/liberl/            |
| Network registry entry              | lib/common/data/network.nix |
| zeiss → Garage egress              | zeiss egress rules         |
| tharbad → Garage egress             | tharbad egress rules        |
| Forward rules for cross-zone access | thebeyond router config     |

---

## Phase 6: CI hardening and observability

**Goal:** Production-grade CI pipeline with caching, scheduled builds,
and fleet visibility.

**Prerequisites:** Phases 1-4 (full pipeline working end-to-end).

### 6.1 Nix store caching for CI

Persist `/nix/var/nix` on erebonia's build storage so built paths survive
reboots. Alternatively, rely on Attic cache for rebuild avoidance (slower
but stateless). Evaluate tradeoffs.

### 6.2 OpenWrt config builds

Extend CI pipeline to build OpenWrt configs
(`nix build .#openwrtConfigurations.*`). These are pure Nix derivations —
no KVM needed.

### 6.3 Scheduled flake update PRs

Woodpecker cron job runs `nix flake update` on a configurable schedule
(weekly) and opens a PR on creil. The PR triggers a test build which must
pass before merge. When the build passes and is approved, the merge triggers
a fleet-wide deployment — enabling automatic weekly updates when nothing is
broken.

Evaluate `woodpecker-flake-pipeliner` or self-hosted Renovate with the Nix
manager for per-input update PRs (e.g., updating nixpkgs-stable and
nixpkgs-unstable independently).

This is separate from Flux-owned cluster dependency updates. Per
`llm-notes/reports/k3s-flux-helm-ownership.md`, Helm charts, raw upstream
manifests, Flux bootstrap artifacts, and selected system images should be
tracked in the cluster dependency registry. The first implementation should use
a repo-native updater/check flow that edits that registry, refreshes
hashes/digests, regenerates committed Flux YAML when needed, and opens an AGit
PR. Renovate can be added later, but only if it edits the authoritative
dependency surface for a given dependency class. When automated, give the
updater a scoped git push credential, a stable AGit topic/title convention, and
a clear policy for manual invocation vs. scheduled runs; start manual until the
checks and review flow are proven.

The Nix-store-preloaded Woodpecker images introduced in the 2026-06-16
Kubernetes backend pass belong in that same dependency-update work even though
they are not Flux-owned workloads. Track
`hosts/erebonia/k3s/woodpecker-images.nix` as a node-local image dependency
surface: update the upstream image digests and fixed-output hashes together,
rebuild/evaluate erebonia, and keep the image refs in the Woodpecker manifests
in lockstep. If the Woodpecker manifests later move to Flux, Flux will reconcile
the workload objects, but the k3s preload archives must still be updated through
the NixOS node configuration for every eligible build node.

### 6.4 Nightly breakage builds

Separate from flake update PRs (6.3). A nightly Woodpecker cron job builds
all NixOS configurations against the current flake.lock without updating
inputs. This catches breakage that may have been introduced by merges to
main since the last successful build — bad configurations, broken module
interactions, or regressions from recent changes.

If the nightly build fails, alert via Alertmanager (6.6). This is a canary:
if nightly builds are green, the fleet is safe to update. If they're red,
something merged to main is broken and needs attention before the next
scheduled flake update PR.

### 6.5 PR review automation

Enhance PR check pipeline:

- Affected-hosts summary comment (which NixOS configurations changed)
- Build size delta reporting
- Link to Attic cache entry for the PR's build artifacts

### 6.6 Fleet activation dashboard

A service subscribing to `activations.>` that exposes Prometheus metrics.
Dashboard on tharbad showing:

- Last activation per host (timestamp, status, generation)
- Deployment latency (event published → activation complete)
- Rollback history

### 6.7 CI failure alerting

Alertmanager rules for:

- Failed CI on main branch (push builds)
- Failed nightly breakage build (6.4)
- Coordinator rollback events
- NATS cluster quorum loss

### 6.8 Secret rotation documentation

Document rotation procedures for:

- CI signing keypair
- Attic push token
- NATS NKey credentials per host
- Woodpecker OAuth2 client secret

---

## Phase 7: AI-driven PR workflows

**Goal:** AI coding agents can propose changes via PRs that CI validates.

**Prerequisites:** Phase 1 (Woodpecker running, PR builds working).
Can be done in parallel with Phases 3-6.

### 7.1 PR check pipeline

Woodpecker config service generates a PR check pipeline triggered on
`pull_request` events:

- `nix fmt -- --check .`
- `nix build .#checks.x86_64-linux.*` (all checks)

Forgejo reports status on the PR.

### 7.2 Branch protection on creil

Configure the dotfiles repo on creil:

- Protected branch: `main`
- Required status checks: PR check pipeline must pass
- Required reviews: at least 1 (human approval gate)
- Admin override: direct push for critical fixes when CI is down

### 7.3 AI agent access

AI agents (running on edith, angbar, or locally) need:

- Git push access to creil (SSH key or access token for pushing branches)
- Forgejo API access for PR creation (personal access token or OAuth2 via
  Authelia, once wired)
- No deploy access — the merge button is the human gate

### 7.4 ci-bot user (optional)

Shared Forgejo identity for AI-authored PRs. Push access, no admin access,
API token in sops. Keeps AI PRs visually distinct from human commits.

---

## Implementation Sequence

```
Phase 1: Woodpecker CI ──────────────────────────────────────────►
Phase 2: Attic integration ──────► (depends on Phase 1)
Phase 7: AI PR workflows ────────► (depends on Phase 1, parallel with 3-6)
Phase 3: NATS cluster ──────────────► (depends on Phase 2)
Phase 4: Fleet coordinator ─────────────► (depends on Phase 3)
Phase 5: Garage S3 ─────────────────────► (depends on Phase 2, parallel with 3-4)
Phase 6: CI hardening ──────────────────────► (depends on Phases 1-4)
```

Phases 5 and 7 are independently useful and can proceed in parallel with the
NATS/coordinator work. Phase 7 only requires Phase 1 (working CI with PR
builds).

---

## New Infrastructure Summary

| Component          | Count | Resources each        | Host(s)                      |
| ------------------ | ----- | --------------------- | ---------------------------- |
| Woodpecker server  | 1     | 1 vCPU, 1GB RAM, 25GB | saint-arkh (erebonia)        |
| Woodpecker runners | n/a   | per-pipeline pods     | erebonia k3s                 |
| NATS microVMs      | 3     | 1 vCPU, 128MB, 512MB  | liberl, erebonia, calvard |
| Coordinator daemon | 3     | minimal (systemd svc) | liberl, calvard, erebonia |
| Garage             | 1     | TBD                   | liberl                    |

Total baseline new RAM: ~1.4GB (1GB Woodpecker server + 384MB NATS nodes), plus
per-build pod resource requests while CI is active. The Woodpecker server
replaces a standing Forgejo runner role with a control-plane-only service; build
pods can temporarily consume more than the old standing runner depending on
concurrency.

---

## Secrets Inventory

| Secret               | Managed by | Stored on  | Used by                         |
| -------------------- | ---------- | ---------- | ------------------------------- |
| CI signing key       | sops-nix / k8s secret | build namespace | Woodpecker build pods |
| Attic push token     | sops-nix / k8s secret | build namespace | Woodpecker build pods |
| NATS CI NKey         | sops-nix / k8s secret | build namespace | Woodpecker build pods |
| NATS host NKeys (×3) | sops-nix   | per host   | Per-host coordinator            |
| Woodpecker backend credentials | sops-nix / k8s secret | build namespace | Woodpecker Kubernetes backend |
| Woodpecker OAuth2    | sops-nix   | saint-arkh | Woodpecker server               |
| Attic public key     | git        | repo       | All hosts (trusted-public-keys) |
| CI public key        | git        | repo       | All hosts (trusted-public-keys) |

All runtime secrets via sops-nix → tmpfs. Public keys committed to
`lib/common/data/`. No secrets in Woodpecker's database-backed store.

---

## Open Questions

1. **NATS microVM names.** Need Trails-themed names for three NATS nodes:
   one Crossbell city (liberl), one Erebonian city (erebonia), one
   Calvard city (calvard). These should be assigned before Phase 3.

2. **Config service implementation.** Evaluate `woodpecker-flake-pipeliner`
   (pinpox) — if it's incompatible or abandoned, the replacement is bounded
   (~200-300 lines).

3. **KVM-capable CI build class for nixosTest.** Nested KVM works on erebonia,
   but the Kubernetes backend still needs a deliberately scoped build profile
   for VM integration tests. Decide whether that is a trusted pod with `/dev/kvm`
   passthrough, a separate out-of-cluster runner path, or a split where pure/eval
   checks run in k8s first and VM checks follow later.

4. **Garage sizing.** Need to estimate storage for Attic chunks on liberl's ZFS
   pool before deploying. VictoriaLogs remains local unless a future storage
   review says otherwise.

5. **Attic storage backend migration.** When migrating Attic from local
   storage to Garage S3 (Phase 5), need a migration path for existing
   cached NARs. Evaluate whether a clean start is acceptable (re-push
   from CI) or if existing data must be migrated.

---

## Deferred Items (Separate Plans)

- **Container registry / OCI image builds** — Forgejo container registry plus
  k3s/Flux deployment integration. Deferred until the workloads plan settles the
  dynamic-manifest path.
- **Central coordinator** — fleet-wide orchestration beyond per-host
  `dependsOnActivation`. Not needed until per-host model fails a real need.
- **Coordinated fleet-wide rollback** — requires central coordinator.
- **Result aggregation service** — structured subscriber to `activations.>`.
  Can be added later without modifying other components.
