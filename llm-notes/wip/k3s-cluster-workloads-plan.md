# k3s Cluster Workloads Plan (AI coding layer, game servers, CI, blog)

Status: **In progress.** **Phase A (AI coding layer / dev containers) runs
first** as the cluster's low-stakes starter and shakedown — ahead of the
dev-environment migration. The remaining net-new features (blog, game servers,
CI) come **after** the dev-env migration.

**Done so far:**

- **Phase A prerequisite — apiserver OIDC auth (2026-06-05).** Phase A's auth
  model is "the operator's existing k8s access (OIDC kubectl/kubeconfig)", but
  bootstrap only shipped the x509 break-glass kubeconfig and deferred OIDC
  (open decision #1 chose the foundational Authelia as the target but did not
  implement it). This chunk wired it: a public+PKCE `kubernetes` OIDC client on
  the foundational Authelia (`messeldam`, `…/messeldam/modules/authelia.nix`)
  carrying `claims_policy: with_groups` (k8s reads groups from the ID Token —
  same gotcha step-ca hit); the k3s apiserver `oidc-*` flags + step-ca
  `oidc-ca-file` and an `oidc:k8s-admins`→cluster-admin ClusterRoleBinding
  (`hosts/erebonia/k3s/default.nix`); the `k8s-admins` lldap group
  (`…/messeldam/modules/lldap.nix`, operator adds their account via the lldap
  UI); and the workstation `kubectl oidc-login` config + kubelogin-oidc
  (`home/modules/kube.nix`). erebonia↔messeldam:443 is intra-VLAN-11, so no
  router6 change. x509 admin kubeconfig stays the break-glass path, so a
  bad/unreachable issuer degrades to "OIDC login fails", never a lockout.
  **Operator validation pending:** rebuild messeldam (lldap seeds `k8s-admins`)
  - erebonia, add your lldap account to `k8s-admins`, copy the k3s server CA to
    `~/.kube/erebonia-ca.crt`, then `KUBECONFIG=~/.kube/erebonia-oidc.yaml kubectl
get nodes` should auth via the browser and land as cluster-admin. (This is
    decision #1's "validate `kubectl oidc-login` in Phase 1" — if Authelia↔kube
    OIDC mismatches, fall back to an oauth2-proxy adapter or static token.)

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 2–4** and Appendix A (CI runner security). The AI coding layer is
_not_ in the report — it's the successor goal to cc-sandbox (which is
unused and being retired, not migrated; see
`k3s-deployd-migration-plan.md`). The report ran blog/game/CI as the
cluster's _first_ workloads; here Phase A is the first workload and the rest
run after the dev-env migration, per operator priority.

Depends on:

- `llm-notes/done/k3s-cluster-bootstrap-plan.md` (the cluster, runtimes,
  and Flux must exist first; the AI coding layer's optional nested-virt
  sessions additionally need the kata-qemu/runc-kvm + `/dev/kvm` path
  validated in bootstrap Phase 1). **Storage:** Phase A uses bootstrap's
  local-path; the **game server (Phase 3)** needs CSI — stood up by the
  dev-env plan (Phase 6.5), which precedes it, or here if game servers
  somehow land first.
- **Phase A runs before** `llm-notes/plans/incus-workstation-migration-plan.md`
  (it's the shakedown that proves the cluster ahead of the edith move). The
  **remaining** features (Phases 2–4) land after the dev-env migration.

Interacts with:

- **`llm-notes/plans/cicd-fleet-activation-plan.md`** — its Phase 1 makes
  `saint-arkh` the **Woodpecker server microvm**. Under the **hybrid**
  decided here, that server microvm stays, but build runners move into the
  cluster via the Woodpecker **kubernetes backend** (replacing the
  bare-metal-agent execution model). See "CI architecture: hybrid" below.
- **`llm-notes/specs/cicd-fleet-management.md`** §9 (container
  integration) is written against deployd's API; it needs re-pointing at
  k8s deploy events.
- The planned-but-never-built deployd game-server iSCSI add-on (deployd
  milestone "D4", from the now-deleted dynamic-container-layer spec) is
  replaced here by CSI VolumeSnapshot. deployd has been retired
  (`llm-notes/done/k3s-deployd-migration-plan.md`).
- Friend-facing game-server access is tracked in
  `llm-notes/plans/headscale-integration-plan.md` (Headscale/subnet-router
  track), which predates the cluster direction — game servers are now
  cluster workloads (CSI VolumeSnapshot for world state) rather than
  calvard microvms, and should be reconciled with that plan.

These workloads land in the **dynamic layer** (Flux-watched manifests in
the chosen dynamic-manifest path), **not** as NixOS modules.

---

## Phase A — AI coding layer via DevPod (first workload, cluster shakedown)

A motivating goal of the whole k3s effort: **a better AI-assisted coding
layer** — on-demand dev containers, replacing the cc-sandbox workflow.
Per operator direction (2026-06-01) this uses an **off-the-shelf external
tool, not a bespoke build**. The report names two (Appendix D, "Specific to
the cc-sandbox-shape problem"): **DevPod** and **Coder**.

**Recommendation: start with DevPod; adopt Coder only if dev environments
go multi-user.** Both run the same dev-container Pods on the same
gVisor/kata runtime tiers, so this is a control-plane-shape choice, not a
security or capability one — and the homelab's principles tip it to DevPod:

- **DevPod** (https://devpod.sh/) — **recommended.** Clientless, CLI-driven,
  uses the open `devcontainer.json` spec checked into each repo. No
  always-on server, no database — fits "infrastructure as LLM-readable text
  in git, avoid opaque web-UI/DB runtime state" (the same principle behind
  Perses-over-Grafana), and adds minimal platform surface for a low-stakes
  shakedown. Its on-demand `devpod up` model maps cleanly onto "spin up an
  isolated container for an AI coding session."
- **Coder** (https://coder.com/) — the **upgrade path**, not the starting
  point. A "productized cc-sandbox": OIDC login, Terraform templates,
  per-user workspaces as Pods (or KubeVirt VMs) with PVCs, idle-shutdown,
  web terminal + SSH + IDE, quotas, audit logs. Its value is **multi-user**
  management (web provisioning UI, per-user quotas/audit) — overkill for a
  single operator, and its Postgres + web-UI control plane is exactly the
  mutable-runtime-state shape the homelab avoids. Adopt it if/when dev
  environments expand beyond the operator (friends, collaborators,
  workshops) or a managed web-IDE platform is wanted. The report led with
  Coder because it assumed cc-sandbox's full feature set was being
  preserved; with cc-sandbox dropped and Phase A scoped as the _minimal_
  starter, that inverts.

This is also the **low-stakes workload the cluster starts with** — it runs
**first**, before the dev-environment migration, and serves as the cluster
shakedown that proves things before the daily-driver edith moves (see
`incus-workstation-migration-plan.md`). It is the one part of this plan pulled
ahead of the dev-env migration; the rest (blog/game/CI) stays later.

Shape (DevPod):

- **No always-on control plane.** DevPod is a CLI with a **Kubernetes
  provider**; `devpod up` builds/starts a workspace Pod on the cluster from
  a repo's `devcontainer.json`. The cluster-side prerequisite is just access
  (a kubeconfig/ServiceAccount scoped to a workspace namespace) — nothing to
  declare as a platform HelmChart. The CLI itself runs wherever the operator
  drives it (a trusted host, or inside another container).
- **Workspaces are dev containers (Pods)** from per-repo `devcontainer.json`
  in git (e.g. a "claude-sandbox" devcontainer). Containers, not VMs — the
  lighter shape that makes this the low-stakes starter.
- **Isolation via the cluster's runtime tiers**, selected per workspace
  (`runtimeClassName` in the provider/pod options): gVisor (`runsc`) for
  ordinary workspaces; `kata-qemu` for stronger isolation. Full nested-virt
  (`/dev/kvm`, `kata-qemu`/`runc-kvm` running nested NixOS build VMs) is
  **only** for workspaces that build/boot VMs — the exact thing that broke
  under deployd, now fixed by running k3s on erebonia bare-metal — not the
  default. (All tiers validated in bootstrap Phase 1.)
- **Auth** is the operator's existing k8s access (OIDC `kubectl`/kubeconfig),
  not a separate login surface — **wired in the prerequisite chunk above**
  (Authelia OIDC + `oidc:k8s-admins`→cluster-admin). Per-workspace
  NetworkPolicy + router6 bound egress as usual.
- **Repo integration** with Forgejo (`creil`) and the Nix substituter
  (`zeiss` Attic) for fast dev-shell builds; persistent workspace state on
  **local-path** PVCs (the DevPod k8s provider supports a persistent
  workspace volume). No CSI needed here — dev-container state is
  reproducible/low-value, which is part of why Phase A is the low-stakes
  starter; CSI comes later with the dev-env migration.

What we lose vs. cc-sandbox: the hand-tuned cgroup/seccomp profile that was
audited in `packages/deployd-helper/src/validation.rs` — the cluster's
RuntimeClass/PSS model replaces it. Acceptable, given cc-sandbox is unused
and the cluster's isolation tiers cover the threat model. The remaining open
item is the **devcontainer/runtimeClass design** (which base images, which
RuntimeClass per workspace), not whether to build a coordinator.

### Phase A PoC — VALIDATED (2026-06-06)

End-to-end path proven on edith → erebonia: OIDC-authed `kubectl`
(`authcode-keyboard` headless login) → DevPod kubernetes provider → workspace
Pod scheduled, image pulled, container started. Ran the stock
`mcr.microsoft.com/devcontainers/python:3` image and confirmed
`runtimeClassName: kata-clh` actually took on the Pod — so the workspace ran
in a Cloud Hypervisor microVM, not a plain container. Client wiring landed in
`home/modules/kube.nix` (kubeconfig, server CA, step-ca root, and the
kata-clh `POD_MANIFEST_TEMPLATE` partial); the provider is configured
imperatively (operator choice while experimenting), not in home-manager.

**Immediate follow-up — SUPERSEDED by
`llm-notes/done/ai-dev-machine-kubevirt-plan.md`.** The substance below
(devcontainer.json + custom image + scripting) is carried forward there, but
the _runtime substrate decision changed_: dev machines run as **KubeVirt VMs**
(regular kernel, native nested `/dev/kvm`) with devpod running the
`devcontainer.json` as a runc container _inside_ the VM — **not** `kata-clh`
pods with the custom nested guest kernel. The PoC above still stands as proof
the cluster + OIDC + devpod path works; the `kata-clh`/runtimeClass guidance in
this section is historical. That plan covers all five open items (substrate,
image, scripting, scoped git credential, network lockdown).

> **Complete (2026-06-10).** That plan's Phases 1–4 landed, and its lockdown +
> mobile pieces — **Phase 5 (network lockdown)** and **Phase 6 (mobile access)** —
> are now **proven**; the plan has moved to
> `llm-notes/done/ai-dev-machine-kubevirt-plan.md`. Phase 5 shifted the dev-machine
> VM onto a lesser-privileged **cluster VLAN (51) with no host access** (Multus +
> macvtap, multus-only) so bt8gw fw4 — not an in-cluster policy — is the sole
> enforcer; the VLAN-shift was a deliverable of
> `llm-notes/wip/workload-network-isolation-plan.md` (its critical-path slice is
> done, broader phases remain). **Consequence for Phase A here:** the dev/AI-coding
> layer is now usable **and** locked down end to end. Net-new workloads below
> (blog, game servers, CI) are unaffected.

**Immediate follow-up — devcontainer definition + custom image for this repo.**
The PoC used a generic upstream image; the actual coding layer needs a
`devcontainer.json` checked into this flake repo plus a purpose-built image so
sessions land with the homelab's tooling, not a stock Python container.

- **`devcontainer.json` in the repo root** (DevPod's per-repo model): pin the
  custom image, set `runtimeClassName`/options as needed, and declare the
  workspace shape (mounts, post-create). This is the artifact `devpod up`
  consumes — the repo becomes self-describing for AI coding sessions.
- **Custom image** carrying the flake's dev tooling — Nix + this flake's dev
  shell, `kubectl`, `claude-code`, and the usual CLIs — so a workspace can
  build/eval the flake immediately. Build it with Nix tooling, **nixpkgs
  packages over `npm install`** in the image (see
  [[feedback_nixpkgs_over_npm]]), and push to the homelab registry (`creil`
  Forgejo) for the provider to pull. Wire the flake dev-shell + Attic
  substituter (`zeiss`) so in-workspace builds hit the cache.
- **RuntimeClass per workspace:** default to `kata-clh` (validated). The
  nested-virt tier (`/dev/kvm` for workspaces that build/boot VMs) stays a
  separate, opt-in shape — out of scope for this immediate follow-up.

This is the remaining substance of Phase A: the runtime is proven, what's left
is making the workspace _useful_ and reproducible from the repo.

## Phase 2 — the blog (optional)

Genuinely optional — the blog isn't a homelab priority. Build it if
there's content to ship; otherwise skip straight to Phase 3/4. (Phase A is
the actual first workload; the blog is just the lowest-stakes of the
report's original three.)

- Deployment + Service + Flux reconciler watching the content repo for
  image updates.
- Cluster Traefik routes `blog.*` to the pod; **langport's nginx**
  forwards public traffic to erebonia's k3s ingress (existing reverse-proxy
  pattern — langport is the dmz reverse proxy, `10.91.100.x`/dmz).
- Lowest-stakes exercise of the full stack: image pull, scheduling,
  ingress, public routing.

The homelab's prior guidance was "provision a dedicated microVM when a
website is ready to host again" (the blog/homepage OCI containers on ardent
were retired during the service split). This plan supersedes that for the
blog specifically: the cluster is the new home for it.

## Phase 3 — game server with CSI snapshot

- Pick the smallest planned game (likely Minecraft).
- World volume on **democratic-csi** (liberl iSCSI backing). CSI is stood
  up by the dev-env plan (Phase 6.5), which precedes this; if for some
  reason game servers land first, do the iSCSI/CSI work here (bootstrap D).
- Validate **suspend → VolumeSnapshot → resume**. This is the prototype
  that was originally going to be the deployd iSCSI add-on (deployd's
  never-built "D4" milestone). CSI VolumeSnapshot replaces the custom iSCSI
  add-on entirely.
- Friend-facing exposure stays consistent with the friend-access model
  (`llm-notes/reports/friend-access-schemes.md` and the roadmap's Headscale
  track) — routed/authenticated at the edge, not by opening the cluster.

## Phase 4 — CI runners

Deploy Woodpecker CI with per-pipeline-step ephemeral pods and the
defence-in-depth stack from report **Appendix A**:

- **gVisor (`runsc`) RuntimeClass** as the sandbox boundary for untrusted
  build code (containers are not a security boundary on their own).
- **Pod Security Standards: Restricted** on the builds namespace.
- **NetworkPolicy + router6** both must allow — egress derived from the
  network registry (`forHost`), templated, not hardcoded.
- **Kyverno** ClusterPolicies scoped to the builds namespace (installed in
  the bootstrap plan), enforcing resource limits and admission rules.
- **Secrets scoping** per the appendix.
- Validate the actual CI workload set under gVisor before betting on it;
  fall back per-job to `runc` + Restricted PSS + NetworkPolicy if a job
  hits a gVisor syscall gap.

CI build pushes target **creil** (Forgejo registry). The report flags
Forgejo's bundled registry as basic — may need Harbor or similar as CI
throughput grows; defer until measured pressure.

### CI architecture: hybrid (decided 2026-06-01)

The Woodpecker CI runtime and the cluster orchestrator are two different
things with different roles, so they live on different surfaces:

- **Woodpecker server stays a microvm** — `saint-arkh` keeps its role from
  `cicd-fleet-activation-plan.md` Phase 1 (the Woodpecker server microvm).
  It is **not** decommissioned; the report's "decommission saint-arkh"
  stance does not apply under the hybrid.
- **Build runners move into the cluster** — Woodpecker uses the
  **kubernetes backend** (`WOODPECKER_BACKEND=kubernetes`), so per-pipeline-
  step pods schedule onto the k3s node (erebonia, bare-metal) with the
  Appendix-A security stack (gVisor RuntimeClass, PSS Restricted,
  NetworkPolicy, Kyverno). This replaces the
  `cicd-fleet-activation-plan.md` Phase 1 "agents on erebonia bare-metal
  via containerd+kata" execution model — the runners are k8s pods now, not
  standalone agents.
- **The NixOS fleet-activation coordinator is a third, separate role** —
  the per-host Rust coordinator + NATS/Attic closure-delivery layer
  (`cicd-fleet-management.md`) is unaffected by where CI runs and proceeds
  independently. CI builds; the coordinator activates closures; the cluster
  orchestrates build pods. Three roles, not one.

Net: this keeps both plans mostly intact — `cicd-fleet-activation-plan.md`
keeps saint-arkh as the Woodpecker server, but its runner-execution
substrate becomes the k3s kubernetes backend instead of bare-metal agents.

**Follow-up edits to land with this plan:**

- Update `cicd-fleet-activation-plan.md` Phase 1 to set
  `WOODPECKER_BACKEND=kubernetes` and drop the bare-metal-agent /
  containerd+kata runner wiring (runners are cluster pods).
- Reconcile the `saint-arkh` registry comment ("Forgejo Actions CI/CD
  runners", `lib/common/data/network.nix:125`) to "Woodpecker CI server" —
  `cicd-fleet-management.md` already standardised on Woodpecker.

### Reconcile cicd spec §9

`cicd-fleet-management.md` §9 ("Future Direction: Container Integration")
builds container deploys on `builds.containers.*` events calling the
**deployd API** (depends on deployd D3/D1c). With deployd removed, that
section should be rewritten to target k8s deploy events (Flux
reconciliation or a small apiserver-talking controller) instead. Out of
scope for the build here, but flag it when touching the cicd plan.

## What lands in the dynamic layer vs NixOS

NixOS/flake (provided by the bootstrap plan): runtimes, Kyverno, Flux,
ingress, local-path storage. (CSI is added later — dev-env Phase 6.5.)
**This plan's deliverables are all manifests** —
Deployments/StatefulSets/Services/NetworkPolicies/ConfigMaps — in the
Flux-watched path, plus langport nginx forwarding rules (NixOS) for any
newly public-facing service.

## Control-plane CA/token ownership — follow-up (do before declaring the k3s migration finished)

Surfaced during Phase A: DevPod's kubeconfig needs to trust the apiserver,
which exposed that k3s' control-plane CAs + server token were
cluster-generated and not owned by the flake (edith was copying the CA out
of erebonia by hand). That ownership transfer has since **landed in code**:
the flake now owns and reproduces erebonia's control-plane roots —
`hosts/erebonia/k3s/ca-adoption.nix` (sops keys + a seed-if-absent step into
`server/tls`), `lib/common/data/k3s/erebonia/` (public CA certs, exposed as
`data.k3s.erebonia`), and `services.k3s.tokenFile`. edith now trusts
`server-ca.crt` from the flake (`home/modules/kube.nix`) — no manual copy.

- **Owned (operator-lifecycle; codified):** 5 CAs (server / client /
  request-header / etcd-server / etcd-peer) + `service.key` (SA issuer
  anchor) + `server-token` (PBKDF2 root of the datastore bootstrap).
- **NOT owned (k3s-autonomous; excluded):** all leaf certs,
  `service.current.key`, `node-token`/`agent-token` (derived from the token).
- **Deciding test:** autonomous rotation by k3s ⇒ k3s-owned; operator-only
  rotation ⇒ ours. "Has a rotate verb" alone is not the test — CAs and the
  token both rotate via operator-run k3s verbs and stay ours.

**Open action — secret-rotation helper.** k3s does not watch cert files;
rotation is repo-authored but **operator-applied** via k3s verbs (the seed is
deliberately seed-if-absent, so editing a secret never auto-rotates). Add a
small script that, on deploy, detects a changed owned secret (hash vs. a
stored applied-hash on `/persist`) and dispatches to the correct verb rather
than overwriting files:

- **token / `service.key`** — automate: read the live value, take the new
  value from sops, run `k3s token rotate --new-token=…` (token) / the SA-key
  rotation procedure (`service.key`). Tractable to do safely.
- **CA certs/keys** — **keep manual** (runbook, not the hook): `k3s
certificate rotate-ca` + restart + client redistribution (`home-manager
switch` for edith's `server-ca`) has too large a blast radius for a
  fire-and-forget trigger.

Until the helper lands, the safe model is: rotate on the cluster with the k3s
verb, then re-capture the new material into the repo (same flow as the
initial adoption). Optional cleaner end-state at a future erebonia reinit:
**Regime B** — generate the CA material in the flake and feed it to k3s via
custom-CA seeding on a fresh init, so the repo is the authoritative origin
(same owned files; only the origin flips repo→cluster).

## Open decisions

- ~~CI architecture fork~~ — **resolved: hybrid** (Woodpecker server
  microvm + kubernetes-backend runners in-cluster). See above.
- ~~AI coding layer tool: Coder vs DevPod~~ — **resolved: DevPod** to
  start (Coder is the multi-user upgrade path). See Phase A. Remaining:
  the devcontainer/runtimeClass design (base images, RuntimeClass per
  workspace) — configuring an off-the-shelf tool, not building one.
- Dynamic-manifest repo layout (inherited from the bootstrap plan's open
  decision #4) — decide before Phase A (the first workload) lands.
- Whether the blog is worth building at all, or Phase 2 is skipped.
