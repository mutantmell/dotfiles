# k3s deployd Migration Plan (cc-sandbox cutover + deployd decommission)

Status: Planned (not started)

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 5–6**.

Depends on: `llm-notes/plans/k3s-cluster-bootstrap-plan.md` (cluster +
kata-qemu/runc-kvm runtimes + `/dev/kvm` access must exist).

Supersedes / retires:
- **`llm-notes/shelved/deployd-integration.md`** — already shelved citing
  this k8s direction. This plan executes the actual removal.
- **`llm-notes/specs/dynamic-container-layer.md`** — the deployd design
  spec. Once deployd is removed, the spec describes a decommissioned
  system; add a forward-pointer (done as part of this work) and treat the
  cluster plans as the live dynamic-runtime design.

Reworks:
- **`llm-notes/done/cc-sandbox-plan.md`** — cc-sandbox is in `done/` but
  its deploy backend (deployd-api on `roer` → deployd-helper →
  containerd/kata on erebonia) is exactly what this plan replaces. The
  user-facing cc-sandbox CLI / repo-fork / profile / state-volume model is
  unchanged; only the deploy path moves to the k8s API. A forward-pointer
  is added to that done plan.

---

## Why these two phases are paired

cc-sandbox is the *only* real deployd workload, and it's also one of the
strongest motivations for the cluster: its current deployd nested-virt
story is broken, and bare-metal kata-qemu (or runc-kvm) on the cluster
fixes it. Migrating cc-sandbox empties deployd; once empty, deployd is
removed. The report deliberately keeps the deployd-cohabitation period
short (weeks-to-months) rather than the year earlier revisions imagined —
two orchestrators competing for kata workloads on one host is the cost
being minimised.

## Phase 5 — migrate cc-sandbox to the cluster

1. **Validate the runtime first.** Spin up a test pod under `kata-qemu`;
   confirm `/dev/kvm` access works inside the kata VM; run a NixOS test VM
   inside it to confirm nested KVM works. The cluster's bare-metal access
   to the host `/dev/kvm` is what makes this the simple case (no nesting
   penalty) — this is the problem deployd couldn't solve.
   - **Fallback:** if kata-qemu's guest kernel can't run nested NixOS-test
     VMs (recurrence of the kata-kernel-nested issue that drove cc-sandbox
     off kata under deployd — see
     `llm-notes/done/kata-cloud-hypervisor-migration.md` for that
     history), drop those sessions to **`runc-kvm`**, accepting the
     isolation downgrade for sessions that need nested workloads. Decide
     here, per Appendix A.
2. **Reimplement the deploy flow.** Today: OIDC-authenticated
   Pod-creation via `deployd-api` (on `roer`) → `deployd-helper` →
   containerd. Two options, both fine:
   - a small new k8s controller that does the OIDC-authenticated
     Pod-creation, or
   - extend `deployd-api` to talk to the **k8s API** instead of
     `deployd-helper` (more reversible — keeps the existing API surface and
     OIDC wiring on `roer`).
   The OIDC issuer is the homelab provider (`messeldam`/Keycloak today,
   Authelia after `authelia-migration-plan.md`); keep the `deploy` group
   requirement.
3. **Parallel-run.** New cluster-side cc-sandbox alongside the deployd-side
   one for a few sessions to validate parity (sandbox creation, persistent
   Claude state volume, dev-shell build + `nix copy`, repo fork on
   Forgejo/creil).
4. **Cut over** cc-sandbox's CLI to the new endpoint.

### cc-sandbox repo touchpoints

- `packages/deployd-api/` (`auth.rs`, `routes.rs`, `helper.rs`) — extend
  to a k8s client, or leave as-is if a new controller is written instead.
- cc-sandbox CLI config (home-manager tool) — repoint the deploy endpoint.
- Sandbox host note: cc-sandbox currently targets `edith` as the build/dev
  host; the cluster path runs the sandbox pod on erebonia bare-metal.
  Confirm the build/`nix copy` source-of-truth host after cutover.

## Phase 6 — decommission deployd

With cc-sandbox migrated, deployd has no remaining workloads.

- Remove `modules/deployd/` and `modules/common/deployd.nix`.
- Remove `packages/deployd-api/` and `packages/deployd-helper/` (or keep
  `deployd-api` if it was repurposed as the k8s-talking controller in
  Phase 5 — decide based on the Phase 5 choice).
- Remove `common.deployd.enable` and the deployd block from
  `hosts/erebonia/default.nix` (the `vsockHostSocket`/`vsockDirectoryService`
  wiring to `roer`, `runtimes.allowed`, the `deploy-dmz` bridge config).
- **Decommission the `roer` microvm** (`hosts/erebonia/microvm/guests/roer/`,
  the deployd-api host) — unless `roer` is being kept as the cc-sandbox
  controller host per Phase 5.
- Reclaim the network allocation (`roer = 32`, management, in
  `lib/common/data/network.nix`).
- The duplicate nested-KVM modprobe collapses to a single owner: erebonia's
  host-level `boot.extraModprobeConfig` (`hosts/erebonia/default.nix:53`)
  or the agent's containerd/kata config — the deployd copy is gone.
- `/etc/kata-containers/configuration.toml` is now solely owned by k3s'
  runtime; the kata-config coexistence footgun from the bootstrap plan
  collapses.

This ends the deployd cohabitation period. Per the report's sunset
criteria, deployd retirement is appropriate once the cluster has been the
platform for new dynamic work for 12+ months with no rollback events — but
because cc-sandbox is the only workload and the bare-metal pivot directly
fixes its nested-virt problem, the practical trigger is "cc-sandbox runs
reliably in-cluster," not a fixed calendar.

## Stale-reference cleanup (do as part of this work)

- `microvm-inventory.md` does not list the deployd `roer` microvm at all
  (it conflates `roer` with the *renamed-to-messeldam* identity). Reconcile
  when `roer` is removed.
- `feature-roadmap-analysis.md` still lists deployd as a live Authelia
  consumer. Update once deployd is gone.

## Rollback

deployd stays fully declared through Phase 5 (parallel-run window) and is
only removed in Phase 6. If the cluster cc-sandbox path regresses, revert
the Phase 5 cutover commit — the deployd path is still live until Phase 6
lands.
