# k3s Cluster Workloads Plan (blog, game servers, CI runners)

Status: Planned (not started)

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 2–4** and Appendix A (CI runner security).

Depends on: `llm-notes/plans/k3s-cluster-bootstrap-plan.md` (the cluster,
CSI, runtimes, and Flux must exist first).

Interacts with:
- **`llm-notes/plans/cicd-fleet-activation-plan.md`** — its Phase 1
  replaces Forgejo Actions on `saint-arkh` with a **Woodpecker server
  microvm + erebonia bare-metal agents**. This plan proposes Woodpecker
  with the **kubernetes backend in-cluster** instead. These two CI shapes
  conflict — see "CI architecture: decision needed" below.
- **`llm-notes/specs/cicd-fleet-management.md`** §9 (container
  integration) is written against deployd's API; it needs re-pointing at
  k8s deploy events.
- **`llm-notes/specs/dynamic-container-layer.md`** — the planned-but-never-
  built deployd game-server iSCSI add-on (its milestone D4) is replaced
  here by CSI VolumeSnapshot. deployd is shelved
  (`llm-notes/shelved/deployd-integration.md`).
- Game-server hosting also appears in `feature-roadmap-analysis.md` (under
  the Headscale/friend-access track) and `microvm-inventory.md` — both
  predate the cluster direction and should be reconciled.

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

The roadmap's "Deferred: Blog/Homepage Containers" item
(`feature-roadmap-analysis.md`) said "provision a dedicated microVM when a
website is ready." This plan supersedes that for the blog specifically:
the cluster is the new home for it.

## Phase 3 — game server with CSI snapshot

- Pick the smallest planned game (likely Minecraft).
- World volume on **democratic-csi** (liberl iSCSI backing, stood up in the
  bootstrap plan).
- Validate **suspend → VolumeSnapshot → resume**. This is the prototype
  that was originally going to be the deployd iSCSI add-on
  (`dynamic-container-layer.md` milestone D4 / `deployd-integration.md`
  D4 — never built). CSI VolumeSnapshot replaces the custom iSCSI
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

### CI architecture: decision needed

This is the most significant conflict with an **active** plan.

- `cicd-fleet-activation-plan.md` **Phase 1** (currently in `plans/`)
  repurposes `saint-arkh` into the **Woodpecker server microvm** and runs
  **agents on erebonia bare-metal** (containerd + kata), and removes the
  Forgejo Actions runner module.
- This plan / the report run **Woodpecker with the kubernetes backend**
  (`WOODPECKER_BACKEND=kubernetes`) — per-step pods in-cluster — and
  **decommission saint-arkh's planned role**, reclaiming its registry
  allocation (`saint-arkh = 61`, app VLAN 50, labeled "Forgejo Actions
  CI/CD runners" in `lib/common/data/network.nix:125`).

Both are coherent; they are not both worth building. The report's stance
is that the k8s backend supersedes the microvm-agent approach (better
sandbox-runtime integration via containerd shims, autoscaling runner
ecosystem). **Operator must choose** before Phase 4 lands:

1. **k8s backend supersedes** — move `cicd-fleet-activation-plan.md` Phase 1
   to reflect Woodpecker-on-k8s; saint-arkh's planned role is dropped and
   its NixOS fleet-activation core (NATS/Attic/coordinator) proceeds
   independently of where CI runners execute.
2. **Keep the microvm Woodpecker** from `cicd-fleet-activation-plan.md` and
   *don't* run CI in the cluster — drop Phase 4 here.
3. **Hybrid** — Woodpecker server stays a microvm (saint-arkh), but the
   kubernetes backend schedules build pods into the cluster (server outside,
   runners inside). This is arguably the cleanest reconciliation and keeps
   both plans mostly intact.

Whichever is chosen: the `saint-arkh` registry label ("Forgejo Actions")
is stale either way — `cicd-fleet-management.md` already standardised on
Woodpecker. Reconcile the registry comment when this lands.

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

- The CI architecture fork above (blocking for Phase 4).
- Dynamic-manifest repo layout (inherited from the bootstrap plan's open
  decision #4) — decide before Phase 2.
- Whether the blog is worth building at all, or Phase 2 is skipped.
