# k3s deployd Decommission Plan

> **Status: DONE (2026-06-02).** deployd fully removed from the flake:
> `modules/deployd/`, `modules/common/deployd.nix`, `packages/deployd-api`,
> `packages/deployd-helper`, the erebonia `common.deployd` block + helper UID
> wiring, and the `roer` microVM (guest dir, network alloc `roer = 32`,
> monitoredHosts entry, `&sv_roer` + creation rule in `.sops.yaml`, fleet/host
> certs, `keys.json` entries). cc-sandbox retired alongside it
> (`packages/cc-sandbox`, `packages/claude-sandbox-image`,
> `home/modules/cc-sandbox.nix`, edith's home-manager config). The `deployd`
> UID was dropped from the user registry; erebonia keeps its single host-level
> nested-KVM modprobe. erebonia + edith-home configs and network checks all
> evaluate clean. **Orphaned encrypted secret entries** (`deployd-capability-token`,
> `cc-sandbox-forgejo-token`) were left for the operator to drop via `sops`;
> the operator subsequently removed `hosts/erebonia/secrets/secrets.yaml`
> entirely. erebonia lands clean for the k3s bootstrap.

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 5–6** — but reframed: see "What changed" below.

Depends on: **nothing.** This runs **first** — before the k3s bootstrap.
deployd removal needs nothing from the cluster; it just needs confidence
that deployd isn't needed, which is already true (cc-sandbox is unused, see
below). Removing it first means k3s lands on a clean erebonia with no
deployd coexistence to manage (the bootstrap plan calls this out as its
biggest simplification). The k3s cluster is the going-forward replacement
context for any sandboxed-compute need (see
`k3s-cluster-workloads-plan.md` Phase A).

Supersedes / retires:
- The deployd implementation itself, and its design docs. Both the
  implementation-tracking doc (`shelved/deployd-integration.md`) and the
  design spec (`specs/dynamic-container-layer.md`) were deleted as obsolete
  once this k8s direction was settled — git history retains them (including
  the static bridge isolation pattern and the nerdctl→containerd analysis).
  This plan executes the actual removal from the flake; the cluster plans
  are the live dynamic-runtime design.

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
  via an **off-the-shelf dev-environment tool (DevPod recommended, or Coder
  if multi-user)** on the cluster, not a port of cc-sandbox and not a
  bespoke build. That
  successor workload lives in
  `llm-notes/plans/k3s-cluster-workloads-plan.md` (Phase A). The bare-metal
  k3s agent's kata-qemu + direct `/dev/kvm` access fixes the nested-virt
  problem that sank cc-sandbox — and the bootstrap plan's Phase 1
  validation already exercises that path (kata-qemu pod, `/dev/kvm`, nested
  NixOS test VM).

So this plan is now a straight **decommission**: deployd has no active
workload, so it is simply removed. No migration phase, no parallel-run.

## Decommission deployd

deployd has no remaining workloads (cc-sandbox, its only consumer, is
unused), so it is removed **first — before k3s is stood up** — not cut over.
There is no workload to preserve and no deployd↔k3s cohabitation period at
all: by the time k3s lands, deployd is already gone, so the kata-config
sharing, duplicate nested-KVM modprobe, and containerd/CNI/bridge/port
audits that earlier drafts worried about simply don't arise.

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
- The duplicate nested-KVM modprobe collapses to a single owner: keep
  erebonia's host-level `boot.extraModprobeConfig`
  (`hosts/erebonia/default.nix:53`); the deployd copy is gone. (The k3s
  agent later assumes this single declaration is already in place.)
- `/etc/kata-containers/configuration.toml` and the system containerd are
  freed up — so when k3s' agent lands afterward it owns the kata runtime
  outright, with no config sharing to reconcile.

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
