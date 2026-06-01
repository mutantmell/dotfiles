# k3s Cluster Workloads Plan (AI coding layer, game servers, CI, blog)

Status: Planned (not started) — net-new features, after the existing
workloads (the dev environments) are migrated. The **AI coding layer** is
the headline motivating workload (see below); the others follow.

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 2–4** and Appendix A (CI runner security). The AI coding layer is
*not* in the report — it's the successor goal to cc-sandbox (which is
unused and being retired, not migrated; see
`k3s-deployd-migration-plan.md`). The report ran blog/game/CI as the
cluster's *first* workloads; here they run after the dev-env migration, per
operator priority, except that a low-stakes one of them may serve as the
cluster shakedown before the daily-driver edith moves (see the dev-env
plan's "Depends on").

Depends on:
- `llm-notes/plans/k3s-cluster-bootstrap-plan.md` (the cluster, CSI,
  runtimes, and Flux must exist first; the AI coding layer additionally
  needs the kata-qemu/runc-kvm + `/dev/kvm` path validated in bootstrap
  Phase 1).
- Net-new features generally land after
  `llm-notes/plans/k3s-dev-env-migration-plan.md`, though a single
  low-stakes workload here may be pulled earlier as the cluster shakedown.

Interacts with:
- **`llm-notes/plans/cicd-fleet-activation-plan.md`** — its Phase 1 makes
  `saint-arkh` the **Woodpecker server microvm**. Under the **hybrid**
  decided here, that server microvm stays, but build runners move into the
  cluster via the Woodpecker **kubernetes backend** (replacing the
  bare-metal-agent execution model). See "CI architecture: hybrid" below.
- **`llm-notes/specs/cicd-fleet-management.md`** §9 (container
  integration) is written against deployd's API; it needs re-pointing at
  k8s deploy events.
- **`llm-notes/specs/dynamic-container-layer.md`** — the planned-but-never-
  built deployd game-server iSCSI add-on (its milestone D4) is replaced
  here by CSI VolumeSnapshot. deployd is being retired
  (`llm-notes/plans/k3s-deployd-migration-plan.md`).
- Friend-facing game-server access is tracked in
  `llm-notes/plans/headscale-integration-plan.md` (Headscale/subnet-router
  track), which predates the cluster direction — game servers are now
  cluster workloads (CSI VolumeSnapshot for world state) rather than
  calvard microvms, and should be reconciled with that plan.

These workloads land in the **dynamic layer** (Flux-watched manifests in
the chosen dynamic-manifest path), **not** as NixOS modules.

---

## Phase A — AI coding layer (motivating workload)

A motivating goal of the whole k3s effort: **a better AI-assisted coding
layer** — sandboxed, isolated environments for running AI coding agents
against homelab repos. This is the *successor to cc-sandbox's intent*, not
a port of it. cc-sandbox failed because deployd's nested-virtualization
story was broken; the bare-metal k3s agent fixes exactly that.

Design is deliberately open (cc-sandbox's specifics aren't carried
forward), but the shape is:

- **Strong per-session isolation** via the runtime tiers the cluster
  already provides: `kata-qemu` (VM-isolated, with `/dev/kvm` for nested
  workloads such as `nixos-rebuild`/NixOS test VMs) or `runc-kvm` as the
  fallback if kata's guest kernel can't nest. gVisor (`runsc`) for the
  lighter, untrusted-code tier. All validated in bootstrap Phase 1.
- **OIDC-authenticated** session/Pod creation against the homelab provider
  (Keycloak now, Authelia later), gated on a group — the same auth shape
  cc-sandbox used, but reimplemented as a small k8s-native controller (or
  a Flux-managed Job/Pod template), not the deployd-api/helper split.
- **Repo integration** with Forgejo (`creil`) and the Nix substituter
  (`zeiss` Attic) for fast dev-shell builds.
- Persistent per-project state on democratic-csi (VolumeSnapshot backups).

Because it exercises the cluster's strongest isolation path and is
lower-stakes than the daily-driver dev environments, this is a good
candidate for the **cluster shakedown workload** that proves things before
edith migrates (see `k3s-dev-env-migration-plan.md`). Treat the detailed
design as an open item to spec when this phase is picked up.

## Phase 2 — the blog (optional)

Genuinely optional — the blog isn't a homelab priority. Build it if
there's content to ship; otherwise skip straight to Phase 3/4. Whichever
workload is first exercises the same cluster-side plumbing.

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
- World volume on **democratic-csi** (liberl iSCSI backing, stood up in the
  bootstrap plan).
- Validate **suspend → VolumeSnapshot → resume**. This is the prototype
  that was originally going to be the deployd iSCSI add-on
  (`dynamic-container-layer.md` milestone D4 — never built). CSI
  VolumeSnapshot replaces the custom iSCSI add-on entirely.
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
  step pods schedule onto the k3s agent (erebonia bare-metal) with the
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
**deployd API** (depends on deployd D3/D1c). With deployd shelved, that
section should be rewritten to target k8s deploy events (Flux
reconciliation or a small apiserver-talking controller) instead. Out of
scope for the build here, but flag it when touching the cicd plan.

## What lands in the dynamic layer vs NixOS

NixOS/flake (already provided by the bootstrap plan): runtimes, Kyverno,
CSI, Flux, ingress. **This plan's deliverables are all manifests** —
Deployments/StatefulSets/Services/NetworkPolicies/ConfigMaps — in the
Flux-watched path, plus langport nginx forwarding rules (NixOS) for any
newly public-facing service.

## Open decisions

- ~~CI architecture fork~~ — **resolved: hybrid** (Woodpecker server
  microvm + kubernetes-backend runners in-cluster). See above.
- **AI coding layer design** (Phase A) — controller vs Flux-templated Pods,
  session lifecycle, state model, runtime tier per session. Spec it when
  picked up; it's the motivating workload but the design is open.
- Dynamic-manifest repo layout (inherited from the bootstrap plan's open
  decision #4) — decide before the first workload lands (Phase A or 2).
- Whether the blog is worth building at all, or Phase 2 is skipped.
