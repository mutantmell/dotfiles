# CI/CD Infrastructure Plan

Plan date: 2026-03-21

## Current State

Three microVMs exist in the DMZ zone serving the CI/CD pipeline:

| Service | Host | MicroVM Host | Zone | IP | State |
|---------|------|-------------|------|-----|-------|
| **Forgejo** (git hosting) | creil | calvard | dmz (VLAN 100) | 10.97.100.53 | Running. SQLite DB, nginx+ACME, admin user provisioned, packages enabled, mirror enabled. SSH git via port 22. |
| **Forgejo Actions runner** | saint-arkh | erebonia | dmz (VLAN 100) | 10.97.100.61 | Running. Runner registered to creil, `nix:host` + `ubuntu-latest:docker` labels. Podman for Docker compat. 4 vCPU / 4GB RAM. |
| **Attic** (Nix binary cache) | ardent | remiferia | dmz (VLAN 100) | 10.97.100.31 | Running. nginx+ACME frontend at `attic.ardent.internal`. Chunked NAR storage, 3-month GC retention. |

### What's wired up
- Forgejo is accessible at `https://creil.internal/`
- Runner connects to creil over HTTPS (port 443), registered with runner token (sops)
- Attic is accessible at `https://attic.ardent.internal/`
- All three have TLS via step-ca (basel) ACME
- All three have egress filtering, promtail (logs → tharbad/Loki), and node-exporter (metrics → tharbad/Prometheus)
- DMZ zone has forward rules to external (SSH, HTTP, HTTPS) and to management (basel for ACME, tharbad for Loki)

### What's missing
- No CI workflow definitions (no `.forgejo/workflows/` in this repo or any repo on creil)
- No Attic integration — runner doesn't push build artifacts to the cache
- No automated deploy pipeline — deploys are manual (`nixos-rebuild switch --target-host` or `deploy-rs`)
- Runner has no egress rule to reach ardent (Attic) — only reaches creil and tharbad
- No container registry (Forgejo packages are enabled but no OCI registry is configured)
- No webhook or push-triggered pipeline
- The dotfiles repo itself likely lives on GitHub with a mirror on creil (or not mirrored yet)

---

## Vision

A self-hosted CI/CD pipeline where:

1. **Push to Forgejo** triggers a workflow that runs `nix flake check` (or `run-checks.sh` equivalent)
2. **Successful builds** push derivations to the Attic binary cache so other hosts pull pre-built closures
3. **Deploy workflows** (manual trigger or on-merge) deploy to target hosts via deploy-rs
4. **AI-driven PR workflows** — AI coding agents (Claude Code, etc.) work on feature branches, open PRs on Forgejo, and CI validates the changes automatically before human review. The PR check pipeline is the trust boundary: AI proposes, CI verifies, human approves.
5. **Container images** for non-NixOS workloads can be built, stored in a Forgejo container registry, and pulled by Incus guests or Podman services
6. **The pipeline itself is declarative** — workflow files live in the repo, runner config is in NixOS, secrets are in sops

### Design Principles
- **Coordination layer, not dependency**: CI/CD sits above the infrastructure as a convenience layer. Every system it automates (NixOS deploys, OpenWrt image builds, dashboard management) remains fully operable via manual commands if the pipeline is unavailable or broken. Higher layers coordinate lower layers, but lower layers operate independently. This mirrors the OpenWrt strategy: preferred path is CI-built images pushed on a regular cadence, but manual `nix run .#openwrt-deploy` always works.
- **Nix-native first**: The primary artifact is a Nix derivation, not a container image. The binary cache is the main distribution mechanism.
- **Declarative everything**: Infrastructure (NixOS), monitoring dashboards (Perses — chosen specifically for its GitOps/dashboards-as-code approach), firewall rules, and CI workflows are all code in the repo. The CI pipeline validates and deploys all of it.
- **PR-as-trust-boundary**: AI agents can propose changes freely via PRs. CI checks (eval tests, VM integration tests, formatting) gate mergeability. Humans review and merge. No AI-initiated deploys without human approval.
- **Containers supplement, not replace**: OCI images are for workloads that don't fit NixOS (third-party services, dev environments, ephemeral tasks). The NixOS foundation remains the primary layer.
- **Egress-filtered runners**: saint-arkh stays in the DMZ with explicit allowlists. CI jobs that need external access go through the gateway.
- **Incremental rollout**: Each phase is independently useful. Don't block check-on-push on having deploy automation.

---

## Architecture

```
  Developer pushes to Forgejo (creil)
        │
        ▼
  Forgejo webhook triggers Actions
        │
        ▼
  Runner (saint-arkh) checks out repo
        │
        ├── nix flake check (eval tests + VM tests)
        │
        ├── nix build (host configs)
        │
        ├── attic push (cache built derivations)
        │
        └── deploy-rs (optional, on manual trigger)
              │
              ▼
        Target hosts pull from Attic cache
```

AI-driven PR workflow:
```
  AI agent (Claude Code on edith/angbar/local)
        │
        ├── Creates feature branch
        ├── Makes changes
        ├── Pushes to Forgejo (creil)
        └── Opens PR via Forgejo API
              │
              ▼
  Forgejo triggers PR check workflow
        │
        ├── nix flake check (eval + VM tests)
        ├── nix fmt --check (formatting)
        └── Reports status on PR
              │
              ▼
  Human reviews PR, merges → triggers deploy
```

Container registry (future):
```
  Runner builds OCI image (nix2container or dockerTools)
        │
        ▼
  Push to Forgejo container registry (creil)
        │
        ▼
  Incus/Podman guests pull images from creil
```

---

## Phases

### Phase 1: Mirror and basic CI

**Goal:** The dotfiles repo on Forgejo runs checks on push.

- [ ] **1.1 Mirror dotfiles to Forgejo**
  Set up a mirror of the dotfiles repo on creil. Either:
  - Push mirror from GitHub (Forgejo supports mirror repos with `mirror.ENABLED = true`)
  - Or make creil the primary and mirror to GitHub
  Decision: TBD based on preference. If creil is primary, GitHub becomes a backup mirror.

- [ ] **1.2 Create `.forgejo/workflows/check.yaml`**
  A workflow that runs on push to any branch:
  ```yaml
  name: Check
  on: [push]
  jobs:
    check:
      runs-on: nix
      steps:
        - uses: actions/checkout@v4
        - name: Run checks
          run: ./scripts/run-checks.sh -j1
  ```
  The `nix:host` label on saint-arkh means this runs directly on the host (not in a
  container), which is needed for NixOS VM tests that require `/dev/kvm`.

- [ ] **1.3 Add runner egress rules for Nix builds**
  saint-arkh already has HTTP/HTTPS egress to gateway for container pulls, which also
  covers `cache.nixos.org`. Verify that nix substitution works from the runner. If the
  runner needs to reach additional cache servers, add egress rules.

- [ ] **1.4 Handle /dev/kvm access on the runner**
  NixOS VM integration tests (the `testers.nixosTest` checks) need KVM. saint-arkh's
  microvm config uses cloud-hypervisor with 4 vCPU. Verify that nested virtualization
  works (erebonia must pass through `/dev/kvm` or the microvm must expose it). If not,
  either:
  - Enable nested virt on erebonia's kernel (`kvm_intel.nested=1`)
  - Or split checks: eval-only tests run on runner, VM tests run elsewhere
  - Or accept VM tests only run locally (current state) and CI runs eval tests only

- [ ] **1.5 Resource tuning**
  `run-checks.sh -j1` is needed on dev machines to avoid OOM. Saint-arkh has 4GB RAM.
  Evaluate whether this is enough for sequential check builds, or if memory needs to
  increase. The microvm.mem can be bumped in `saint-arkh/microvm.nix`.

### Phase 2: Attic binary cache integration

**Goal:** CI pushes build artifacts to Attic; hosts substitute from Attic.

> **Attic maintenance risk:** Attic (zhaofengli/attic) is a single-maintainer project.
> Last commit September 2025, 121 open issues, 43 open PRs, README calls it "an early
> prototype." No significant community fork exists.
>
> However, this development pattern is **normal for this project and maintainer**.
> The commit history shows a similar ~7-8 month gap in mid-2023 between the initial
> launch and the November 2023 JWT refactor. zhaofengli works in bursts (10-16 commits
> over a few days, then months of quiet) and was still active on Colmena through
> November 2025 — the Attic gap is project prioritization, not disappearance. They
> are a NixOS org member and maintainer of other widely-used tools.
>
> The real risk is not abandonment but unpredictable cadence: if a bug blocks us, we
> may need to patch locally and wait for a merge. Attic's feature set (chunked
> deduplication, S3 backend, GC) is well ahead of alternatives (Harmonia, nix-serve),
> and the task it performs is small and well-scoped. The risk is accepted — if upstream
> goes fully unmaintained, the codebase is small enough to fork or replace. Phase 5
> (Garage) could serve as Attic's storage backend, further decoupling storage concerns.

- [ ] **2.1 Add runner → ardent egress rule**
  saint-arkh needs to reach `attic.ardent.internal` (HTTPS/443). Add to
  `saint-arkh/default.nix` egress rules:
  ```nix
  { host = "ardent"; proto = "tcp"; port = 443; comment = "Attic cache push"; }
  ```

- [ ] **2.2 Create Attic cache and auth token for CI**
  - Create a cache (e.g., `infra`) on Attic
  - Generate a push token for the runner
  - Store the token as a sops secret on saint-arkh

- [ ] **2.3 Add Attic push to CI workflow**
  After successful `nix build`, push the closure to Attic:
  ```yaml
  - name: Push to cache
    run: |
      attic login infra https://attic.ardent.internal --token "$(cat /run/secrets/attic-push-token)"
      attic push infra ./result
  ```
  Or push all check outputs: `attic push infra .#checks.x86_64-linux.*`

- [ ] **2.4 Configure hosts to substitute from Attic**
  On each NixOS host, add Attic as a substituter in `nix.settings`:
  ```nix
  nix.settings = {
    substituters = [ "https://attic.ardent.internal" ];
    trusted-public-keys = [ "<attic-cache-public-key>" ];
  };
  ```
  This goes in `modules/common/` so all hosts benefit. Requires the Attic signing
  key to be distributed (can be a non-secret public key in `lib/common/data/`).

- [ ] **2.5 saint-arkh → ardent DNS resolution**
  saint-arkh's `networking.extraHosts` currently lists `creil` and `tharbad`. Add
  `ardent` so it can resolve `attic.ardent.internal`.

### Phase 3: AI-driven PR workflows

**Goal:** AI coding agents can propose changes via PRs that CI validates automatically.

- [ ] **3.1 PR check workflow**
  Create `.forgejo/workflows/pr-check.yaml` triggered on `pull_request` events:
  ```yaml
  name: PR Check
  on: [pull_request]
  jobs:
    check:
      runs-on: nix
      steps:
        - uses: actions/checkout@v4
        - name: Format check
          run: nix fmt -- --check .
        - name: Run checks
          run: ./scripts/run-checks.sh -j1
  ```
  Forgejo Actions supports PR status checks natively. Configure branch protection
  on `main` to require the check to pass before merge.

- [ ] **3.2 Forgejo branch protection**
  Configure the dotfiles repo on Forgejo with:
  - Protected branch: `main`
  - Required status checks: `PR Check` workflow must pass
  - Required reviews: at least 1 (human approval gate)
  - Push restrictions: merge via PR preferred (but admin can push directly to main
    for critical fixes when CI is down — consistent with coordination-layer principle)
  This is configured via Forgejo's web UI or API, not NixOS config.

- [ ] **3.3 AI agent access to Forgejo**
  AI agents (running on edith, angbar, or locally) need:
  - **Git push access**: SSH key or access token that can push branches to creil.
    The `edith` SSH key is already authorized on creil. For local dev machines,
    the user's SSH cert (from step-ca) can be used.
  - **API access for PR creation**: A Forgejo API token (personal access token or
    OAuth2 token via Keycloak). Store per-agent or use a shared `ci-bot` user.
  - **No deploy access**: AI agents can push branches and create PRs but cannot
    trigger deploy workflows or merge PRs. The merge button is the human gate.

- [ ] **3.4 Create a `ci-bot` Forgejo user (optional)**
  If AI agents should create PRs under a shared identity rather than the user's
  account, create a `ci-bot` user with:
  - Push access to repos (can create branches, open PRs)
  - No admin access
  - API token managed via sops
  This keeps AI-authored PRs visually distinct from human commits.

- [ ] **3.5 PR workflow for external contributions**
  If using GitHub as a mirror with Forgejo as primary, configure GitHub Actions
  to mirror PRs or just use Forgejo as the sole PR destination for AI workflows.
  AI agents should push directly to Forgejo, not via GitHub.

- [ ] **3.6 Review tooling**
  Consider adding to the PR check workflow:
  - A diff summary comment (what hosts/modules are affected)
  - A `nix build` of affected host configs to surface eval failures early
  - Link to test logs for failed checks
  Forgejo Actions can post comments on PRs via the API.

### Phase 4: Deploy automation

**Goal:** Deploy to target hosts via deploy-rs, triggered manually from Forgejo or the command line.

#### Deploy topology problem

saint-arkh (the runner) is a microVM on erebonia. This creates two fundamental
problems with direct SSH-based deployment from the runner:

1. **Security inversion**: A DMZ microVM guest would have SSH deploy access to its
   own parent host (and other parent hosts). The guest can trigger a rebuild of the
   machine that hosts it — privilege flows in the wrong direction.

2. **Ordering / self-destruct**: When deploying to erebonia (saint-arkh's parent),
   the microVM shuts down as part of the host's activation. The deploy process loses
   its controlling process mid-deploy. deploy-rs's magicRollback may or may not
   handle this gracefully depending on timing.

These problems apply to any parent host deployment (calvard, erebonia, remiferia)
but not to standalone hosts (thebeyond, angbar) or hosts the runner doesn't live on.

#### Deployment strategy options

The deployment strategy needs to be decided before implementation. Options:

**Option A: Pull-based via Attic (CI builds, hosts pull)**
- CI builds closures and pushes to Attic (Phase 2 already covers this)
- Each host has a timer or manual trigger that pulls its config from Attic and
  activates it locally (e.g., `nixos-rebuild switch` with Attic as substituter)
- Pros: No security inversion, no ordering issue, hosts control their own lifecycle
- Cons: Requires a pull/activation mechanism on each host, more moving parts,
  harder to get deployment status feedback back to CI

**Option B: External deployer (not on the runner)**
- Deploys are triggered from a trusted location outside the microVM fleet — e.g.,
  the operator's workstation, a dedicated deploy host in management zone, or
  thebeyond itself (the router, which is not a microVM parent)
- CI's job ends at "build + cache"; deploy is a separate manual step
- Pros: Clean security boundary, uses existing deploy-rs workflow
- Cons: Requires human in the loop or a dedicated deploy host, less "CI/CD" and
  more "CI then D"

**Option C: Hybrid (direct deploy for safe targets, pull for parents)**
- saint-arkh can directly deploy to hosts it doesn't live on (thebeyond, angbar)
- Parent hosts (calvard, erebonia, remiferia) use pull-based activation from Attic
- Pros: Gets direct deploy where it's safe, avoids the inversion where it's not
- Cons: Two deployment mechanisms to maintain

**Option D: Runner on bare metal or dedicated deploy zone**
- Move the runner (or a deploy-specific agent) out of the microVM fleet to avoid
  the guest-deploys-host problem entirely
- Pros: Eliminates the topology issue at the source
- Cons: Requires dedicated hardware or a non-microVM deployment slot

This is a key architectural decision that affects Phase 4 implementation and
should be resolved before starting deploy work.

#### Phase 4 items (once strategy is decided)

- [ ] **4.1 Decide deployment strategy**
  Evaluate options A-D above. The choice affects networking, security, and what
  mechanisms need to be built. The coordination-layer principle applies: whatever
  is chosen, `deploy-rs` or `nixos-rebuild switch --target-host` from the operator's
  workstation must always remain a working fallback.

- [ ] **4.2 Add deploy-rs nodes for all deployed hosts**
  Currently only thebeyond has a deploy-rs definition. Add calvard, erebonia, remiferia.
  (This is also item 4.2 in the repo review action plan.) This is useful regardless of
  which deploy strategy is chosen — deploy-rs nodes are needed for manual deploys too.

- [ ] **4.3 Ensure rollback is enabled on all nodes**
  deploy-rs has `magicRollback` and `autoRollback` which handle rollback automatically
  if activation fails. Ensure these are enabled for all deploy nodes (thebeyond already
  has them).

- [ ] **4.4 Implement chosen deploy strategy**
  Networking, workflows, and activation mechanisms depend on the decision in 4.1.
  If direct deploy (to any target): runner SSH access, egress rules, deploy workflow.
  If pull-based: host-side activation timer/trigger, Attic notification mechanism.
  If hybrid: both, scoped to the appropriate targets.

### Phase 5: S3-compatible object storage (Garage)

**Goal:** Self-hosted S3-compatible storage as shared infrastructure for multiple services.

[Garage](https://garagehq.deuxfleurs.fr/) is a lightweight, self-hosted, S3-compatible
distributed object store designed for edge/homelab deployments. It's actively maintained
by the Deuxfleurs association, low-resource, and supports multi-node replication if needed
later.

#### Why Garage

Multiple services in the stack benefit from S3-compatible storage:

1. **Loki log storage** — Loki's TSDB+chunks architecture is designed for object storage.
   Currently using local filesystem on tharbad (2GB RAM, 30GB persist volume). S3 backend
   decouples log retention from tharbad's disk, allowing longer retention with a known GC
   cycle. This is the most concrete near-term use case.

2. **Container registry backend** — If Phase 6 (container registry) happens, image layers
   can be stored in Garage rather than on creil's local disk.

3. **Attic chunk storage** — Attic supports S3 backends. Moving chunk storage to Garage
   decouples Attic's cache storage from ardent's persist volume, letting storage live on
   remiferia (which has the ZFS pool and real disk capacity).

#### Placement

Garage would most naturally run on remiferia (the NAS with ZFS storage) or as a microVM
on remiferia. The S3 API endpoint needs to be reachable from the DMZ (ardent/Attic) and
management zone (tharbad/Loki). This is similar to existing cross-zone patterns.

#### Items

- [ ] **5.1 Evaluate Garage resource requirements**
  Single-node Garage for homelab use. Estimate storage needs across use cases
  (Loki retention, Attic chunks, container images if applicable).

- [ ] **5.2 Deploy Garage**
  Garage microVM on remiferia or directly on remiferia. S3 API + web endpoint.
  TLS via step-ca ACME. Egress filtering. Network registry entry.

- [ ] **5.3 Migrate Loki to S3 backend**
  Reconfigure Loki on tharbad to use Garage for chunk storage. Adjust retention/GC
  policies now that storage is decoupled from tharbad's persist volume.

- [ ] **5.4 Migrate Attic to S3 backend (optional)**
  Point Attic's chunk storage at Garage. Reduces ardent's persist volume requirements.

- [ ] **5.5 Cross-zone networking**
  Firewall rules for DMZ → Garage (Attic) and management → Garage (Loki).
  Egress rules on ardent and tharbad for the Garage endpoint.

### Phase 6: Container registry

**Goal:** Build and distribute OCI images for non-NixOS workloads.

- [ ] **6.1 Enable Forgejo container registry**
  Forgejo already has `packages.ENABLED = true`. The container registry is part of
  Forgejo packages. Verify it works by pushing a test image:
  ```bash
  podman login creil.internal
  podman push localhost/test:latest creil.internal/forgejo-admin/test:latest
  ```

- [ ] **6.2 Build OCI images in Nix**
  Use `pkgs.dockerTools.buildImage` or `nix2container` to produce OCI images
  declaratively. These can be added as flake outputs:
  ```nix
  containerImages.my-service = pkgs.dockerTools.buildImage { ... };
  ```

- [ ] **6.3 CI pushes images to registry**
  After `nix build .#containerImages.my-service`, push to Forgejo:
  ```bash
  skopeo copy docker-archive:./result docker://creil.internal/infra/my-service:latest
  ```
  Runner already has HTTPS egress to creil.

- [ ] **6.4 Consumer hosts pull from registry**
  Incus guests or Podman services on hosts pull images from `creil.internal`.
  Requires:
  - Hosts in the appropriate zone can reach creil (DMZ) on port 443
  - Trust the step-ca root certificate (already configured on all hosts)

- [ ] **6.5 Evaluate scope of container workloads**
  Decide which workloads actually benefit from being containers vs NixOS services.
  Candidates:
  - Third-party services without good NixOS modules
  - Dev environments with complex dependency stacks
  - Ephemeral CI job environments (already handled by Podman on saint-arkh)
  The default should remain NixOS; containers are the exception.

- [ ] **6.6 Consider Garage as registry storage backend**
  If Phase 5 (Garage) is deployed, the container registry can use it for image layer
  storage instead of creil's local disk. This is one of the identified Garage use cases.

### Phase 7: Pipeline hardening

**Goal:** Production-grade CI with security, caching, and observability.

- [ ] **7.1 Nix store caching between CI runs**
  saint-arkh's `/persist` includes `/var/lib/containers` but not the nix store.
  The nix store is shared from erebonia via virtiofs (`/nix/store` read-only).
  For CI builds, the runner will need local build storage. Options:
  - Persist `/nix/var/nix` so built paths survive reboots
  - Or rely on Attic cache for rebuild avoidance (slower but stateless)

- [ ] **7.2 Workflow for OpenWrt builds**
  Extend CI to build OpenWrt configs (`nix build .#openwrtConfigurations.*`).
  These are pure Nix derivations and don't need KVM.

- [ ] **7.3 Enhanced PR review automation**
  Beyond basic check/format (Phase 3), add richer PR feedback:
  - Affected-hosts summary comment
  - Build size delta reporting
  - Link to Attic cache entry for the PR's build artifacts

- [ ] **7.4 Scheduled builds**
  Run nightly builds to catch breakage from nixpkgs-unstable updates.
  Use Forgejo Actions `schedule` trigger.

- [ ] **7.5 CI observability**
  Runner already has promtail + node-exporter. Add:
  - Workflow duration metrics (Forgejo exposes these via API)
  - Alertmanager rule for failed CI on main branch
  - Dashboard in Perses for CI health (Perses dashboards are declarative/code-managed, so CI health dashboards can live in the repo)

- [ ] **7.6 Secret rotation**
  Runner token, Attic push token, and deploy SSH credentials should be rotatable.
  Document the rotation procedure for each.

---

## Network Changes Summary

All CI hosts are in the DMZ (VLAN 100). The following network changes are needed:

| Change | Where | Phase |
|--------|-------|-------|
| saint-arkh egress → ardent:443 | saint-arkh/default.nix | 2 |
| saint-arkh extraHosts += ardent | saint-arkh/default.nix | 2 |
| All hosts: Attic as nix substituter | modules/common/ | 2 |
| DMZ → management forward: saint-arkh → targets:22 | thebeyond/router.nix | 4 (only if direct deploy strategy) |
| saint-arkh egress → management hosts:22 | saint-arkh/default.nix | 4 (only if direct deploy strategy) |

No new VLANs or zones are needed. The existing DMZ → management forward rules
pattern (used for ACME/Loki) extends naturally to deploy SSH.

## Open Questions

1. **Primary repo location**: Should creil (Forgejo) become the primary remote for
   dotfiles, with GitHub as a push mirror? Or stay GitHub-primary with Forgejo as
   a pull mirror? Affects webhook triggering.

2. **KVM on the runner**: Does nested virtualization work through erebonia →
   saint-arkh (cloud-hypervisor)? If not, VM integration tests can't run in CI.
   May need to limit CI to eval-only tests or add a bare-metal runner.

3. **Runner resource limits**: 4GB RAM for `run-checks.sh -j1` — is this enough?
   May need empirical testing. The checks that OOM on dev machines were from
   parallel evaluation, not sequential builds.

4. **Attic storage**: ardent has 25GB persist volume. How much cache space is
   needed for the infra derivations? May need to increase volume size or tune
   GC retention (currently 3 months).

5. **Container registry scope**: What non-NixOS workloads are planned? This
   determines whether Phase 6 is near-term or deferred.
