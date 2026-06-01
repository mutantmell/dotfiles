# k3s Cluster Workloads Plan (blog, game servers, CI runners)

Status: Planned (not started) — **deferred to last**. Per operator
priority, the existing workloads are migrated onto the cluster before these
net-new features are added.

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 2–4** and Appendix A (CI runner security). Note: the report ran
these as the cluster's *first* workloads; here they run **after** the
migration plans below, because moving existing workloads (cc-sandbox,
edith) over takes priority and those serve as the cluster's proving
workloads instead.

Depends on:
- `llm-notes/plans/k3s-cluster-bootstrap-plan.md` (the cluster, CSI,
  runtimes, and Flux must exist first).
- Existing-workload migration done first:
  `llm-notes/plans/k3s-deployd-migration-plan.md` and
  `llm-notes/plans/k3s-dev-env-migration-plan.md`. The cluster should be
  proven by those migrations before new features land here.

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

All three workloads land in the **dynamic layer** (Flux-watched manifests
in the chosen dynamic-manifest path), **not** as NixOS modules.

---

## Phase 2 — first workload: the blog (optional)

Genuinely optional — the blog isn't a homelab priority. Build it if
there's content to ship; otherwise skip straight to Phase 3/4. Whichever
workload is first exercises the same cluster-side plumbing.

- Deployment + Service + Flux reconciler watching the content repo for
  image updates.
- Cluster Traefik routes `blog.*` to the pod; **langport's nginx**
  forwards public traffic to erebonia's k3s ingress (existing reverse-proxy
  pattern — langport is the dmz reverse proxy, `10.97.x`/dmz).
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
- Dynamic-manifest repo layout (inherited from the bootstrap plan's open
  decision #4) — decide before Phase 2.
- Whether the blog is worth building at all, or Phase 2 is skipped.
