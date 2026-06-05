# k3s Cluster Workloads Plan (AI coding layer, game servers, CI, blog)

Status: Planned (not started). **Phase A (AI coding layer / dev containers)
runs first** as the cluster's low-stakes starter and shakedown — ahead of
the dev-environment migration. The remaining net-new features (blog, game
servers, CI) come **after** the dev-env migration.

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
- **Phase A runs before** `llm-notes/plans/k3s-dev-env-migration-plan.md`
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
`k3s-dev-env-migration-plan.md`). It is the one part of this plan pulled
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
- **Auth** is the operator's existing k8s access (OIDC `kubectl`/kubeconfig
  from the bootstrap plan), not a separate login surface. Per-workspace
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
