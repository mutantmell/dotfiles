# k3s deployd Decommission Plan

Status: Planned (not started)

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 5–6** — but reframed: see "What changed" below.

Depends on: `llm-notes/plans/k3s-cluster-bootstrap-plan.md` (the cluster is
deployd's replacement context). deployd removal itself needs nothing from
the cluster — it just needs the operator to be confident deployd isn't
needed, which is already true (see below).

Supersedes / retires:
- The deployd implementation itself. (Its tracking doc,
  `shelved/deployd-integration.md`, was deleted as obsolete once this k8s
  direction was settled — git history retains it, including the static
  bridge isolation pattern and the nerdctl→containerd analysis.) This plan
  executes the actual removal from the flake.
- **`llm-notes/specs/dynamic-container-layer.md`** — the deployd design
  spec. Once deployd is removed, the spec describes a decommissioned
  system; a forward-pointer was added there and the cluster plans are the
  live dynamic-runtime design.

## What changed (cc-sandbox is unused, not migrated)

Earlier revisions of this plan treated **cc-sandbox** as a workload to
*migrate* onto the cluster (parallel-run, re-point the deploy backend,
preserve the user-facing model). That's no longer the plan:

- **cc-sandbox ended up not very useful** — the nested-virtualization
  limitations of what deployd built meant it never delivered, and it is
  **currently unused**. (operator, 2026-06-01)
- It is **not critical to keep working**. There is nothing worth
  migrating.
- The motivating goal — sandboxed AI-assisted coding — is carried forward
  as a **better AI coding layer built fresh on the cluster**, not a port
  of cc-sandbox. That successor workload lives in
  `llm-notes/plans/k3s-cluster-workloads-plan.md` ("AI coding layer"). The
  bare-metal k3s agent's kata-qemu + direct `/dev/kvm` access is exactly
  what fixes the nested-virt problem that sank cc-sandbox — and the
  bootstrap plan's Phase 1 validation already exercises that path
  (kata-qemu pod, `/dev/kvm`, nested NixOS test VM).

So this plan is now a straight **decommission**: deployd has no active
workload, so it is simply removed. No migration phase, no parallel-run.

## Decommission deployd

deployd has no remaining workloads (cc-sandbox, its only consumer, is
unused). It can be removed whenever convenient after the cluster exists —
there is no workload-cutover to gate on. The previous "weeks-to-months
cohabitation window" concern (two orchestrators competing for kata
workloads on erebonia) largely evaporates because deployd isn't actually
running anything; until removed, it just sits declared.

Removal steps:

- Remove `modules/deployd/` and `modules/common/deployd.nix`.
- Remove `packages/deployd-api/` and `packages/deployd-helper/`.
- Remove `common.deployd.enable` and the deployd block from
  `hosts/erebonia/default.nix` (the `vsockHostSocket` /
  `vsockDirectoryService` wiring to `roer`, `runtimes.allowed`, the
  `deploy-dmz` bridge config).
- **Decommission the `roer` microvm** (`hosts/erebonia/microvm/guests/roer/`,
  the deployd-api host).
- Reclaim the network allocation (`roer = 32`, management, in
  `lib/common/data/network.nix`).
- The duplicate nested-KVM modprobe collapses to a single owner: erebonia's
  host-level `boot.extraModprobeConfig` (`hosts/erebonia/default.nix:53`)
  or the agent's containerd/kata config — the deployd copy is gone.
- `/etc/kata-containers/configuration.toml` is left solely to k3s' runtime;
  the kata-config coexistence footgun from the bootstrap plan collapses.

### cc-sandbox cleanup

cc-sandbox's home-manager CLI tool and any remaining config can be removed
or left to bit-rot harmlessly — it's a client-side tool with no running
backend once deployd is gone. There's no parity bar to meet; nothing
depends on it. (If any AI-coding workflow is wanted, it's the fresh cluster
workload, not cc-sandbox.)

## Stale-reference cleanup (do as part of this work)

- `docs/hostnames.md` lists `roer` as the deployd-api microvm — remove that
  entry when the guest is decommissioned.

## Rollback

deployd stays fully declared until this plan removes it; there is no
intermediate cutover. If for some reason deployd is wanted back before
removal, nothing has changed. After removal, the revert is restoring the
removed commits — but since the cluster (with a better-isolated runtime) is
the going-forward substrate for any sandboxed-compute need, a deployd
revert is not expected.
