# k3s Dev-Environment Migration Plan (edith → KubeVirt, trista, Incus sunset)

Status: Planned (not started)

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 7–9**.

Depends on:
- `llm-notes/plans/k3s-cluster-bootstrap-plan.md` (cluster + CSI).
- Cluster proven by `llm-notes/plans/k3s-deployd-migration-plan.md`
  (cc-sandbox running reliably in-cluster). Per operator priority the
  existing workloads are migrated before the net-new features in
  `llm-notes/plans/k3s-cluster-workloads-plan.md`, so the cc-sandbox
  migration — not the new workloads — is what proves the cluster ahead of
  the edith move. (The report gated this on its Phases 2–4 + ~3 months of
  cluster operation; the proving workload changes with the reordering, the
  "let it run a while first" intent does not.)

Relates to / eventually obsoletes:
- **`llm-notes/done/incus-vm-migration.md`** — converted `edith` to an
  Incus VM and documented the host-side-build + `nixos-rebuild
  --target-host` update model. That model carries forward conceptually;
  the Incus *substrate* is what this plan replaces.
- **`llm-notes/done/incus-module-overhaul.md`** — the `modules/incus/` +
  `modules/common/incus.nix` work this plan eventually removes from
  calvard/erebonia (Phase 9).
- **`llm-notes/done/kata-cloud-hypervisor-migration.md`** — documents *why*
  mutable-NixOS-as-a-container failed (kata-agent vs systemd cgroup-v2
  `EBUSY`). That lesson is exactly why edith goes to **KubeVirt (a real
  VM)**, not Pod + PVC.

---

## Why edith is a KubeVirt VM, not a Pod + PVC

The stated goal of the Incus → cluster migration is "replace Incus with
something **edith-shaped**." edith is a mutable NixOS system (systemd as
PID 1, writable store, home-manager). Pod + PVC + systemd-as-PID-1 has two
real frictions:

1. **PSS Restricted fights systemd-as-PID-1** — it blocks `/sys/fs/cgroup`
   rw and `procMount: Unmasked`, both of which systemd-as-PID-1 wants.
   Falling back to PSS Baseline is an isolation downgrade; falling back to
   a non-systemd init breaks the mutable-NixOS shape.
2. The Coder / Gitpod / Codespaces precedents are container-shaped (thin
   inits), not systemd-as-PID-1 — they don't transfer 1:1.

KubeVirt expresses edith directly (it *is* a VM), keeps NixOS as the guest
OS without contortions, and maps CSI VolumeSnapshot cleanly onto the
`incus snapshot` workflow edith has today. The cost (kubevirt-operator +
virt-handler DaemonSet + CRDs, ~150 MB) is real and is the rejected
alternative's tax to avoid.

## Current edith state (repo-grounded)

- `hosts/calvard/incus/guests/edith/default.nix` — Incus **`dev` profile**,
  `parent = "br21"` (lab VLAN 21), `limits.memory = "16GB"`,
  `limits.disk = "100GB"`, normal user `mutantmell`, eternal-terminal.
- Registry: `edith = 42` → `10.97.21.42`, lab zone
  (`lib/common/data/network.nix:78`; the comment says "calvard Incus
  container" — stale, it's a `dev`-profile guest).
- **Lives on calvard today**; the KubeVirt VM lands on **erebonia** (the
  cluster host) → this is a cross-host migration.

## Phase 7 — migrate edith into the cluster as a KubeVirt VM

1. **Add KubeVirt to the platform.** HelmChart resource in the k3s-server
   microvm's `manifests/` directory (declared in the flake, pinned).
   kubevirt-operator + virt-handler DaemonSet (virt-handler runs on the
   erebonia agent node); CRDs: `VirtualMachine`, `VirtualMachineInstance`,
   `DataVolume`. One new platform component on the update cadence.
   Reversible — revert the HelmChart and edith stays on Incus.
2. **Build the edith VM image** from the flake: a pre-built NixOS disk
   image (qcow2/raw) via `nixos-generators` or the flake-native
   equivalent, reproducible across rebuilds. (cloud-init into a blank
   DataVolume is a valid alternate install path, but flake-built image is
   the canonical "infrastructure is text in git" pattern.)
3. **Define the `VirtualMachine` resource:**
   - CPU/memory matching today's allocation (16 GB per the Incus config).
   - `DataVolume` boot disk on **democratic-csi** (liberl backing);
     VolumeSnapshot for periodic backups.
   - Bridged into the cluster CNI; routed through router6 like any cluster
     workload (preserve a stable address; reconcile the lab-VLAN
     registry entry vs the new cluster placement).
   - cloud-init for any first-boot config the image doesn't carry.
4. **Cutover:**
   - Cross-host disk seed: `incus export` the calvard Incus edith → import
     as a DataVolume on liberl-backed CSI (or snapshot the Incus disk, copy
     via NFS/scp to liberl, import as a PV).
   - Parallel-run a few weeks: validate builds, dev workflows, sshd
     access, the langport routing chain, and VolumeSnapshot backup/restore.
   - Cut over by switching DNS / langport routing to the new edith. Keep
     the **Incus edith declared but stopped** for several more weeks as
     rollback; remove the Incus declaration once confidence is high.

edith is the operator's daily driver — the parallel-run + stopped-Incus
rollback window is the mitigation for that risk.

## Phase 8 — reconcile trista's role

**Authoritative role (operator, 2026-06-01):** trista is an **SSH target
that lives in DMZ and is reachable over the wg-ba mesh**. It **may also be
a task runner**. It is **not** primarily a bastion. This supersedes the
conflicting descriptions previously scattered across the repo:

- `lib/common/data/network.nix` comment said "SSH bastion" — **corrected**
  to the role above as part of this work.
- `hosts/erebonia/incus/guests/trista/default.nix` → profile **`dmz-vm`**,
  `macvlan` on `uplink.100` (DMZ placement — consistent with the role).
- `microvm-inventory.md` → "Dev environment / task runner (backup)" —
  **stale**, still needs the same correction (flagged below).
- `feature-roadmap-analysis.md` (vLAB) → "wg-ba mesh peer" — consistent
  with the role.

Migration shape: an SSH target + occasional task runner is
**container-shaped** — if/when trista moves into the cluster, **Pod + PVC
with a thin init + sshd** (no systemd-as-PID-1) is the right fit, lighter
than KubeVirt. (PSS: thin init + sshd works; PSS Baseline is acceptable for
trusted-code workloads. It is *not* edith-shaped, so KubeVirt is not
warranted.)

The real complication is **wg-ba mesh peering**: a WireGuard mesh peer is
naturally a host/VM, not a Pod. Two options when migration is actually
wanted:
- keep trista as a VM (Incus today, or KubeVirt) so wg-ba peering stays
  host-native — simplest given the mesh role; or
- run it as a Pod in the DMZ zone and terminate wg-ba elsewhere (e.g. on
  the router / an existing mesh peer), routing SSH to the Pod via router6 +
  NetworkPolicy.

**No urgency.** trista has a live, low-churn role; there's no forced
migration. Decide the shape only if/when consolidating off Incus (Phase 9)
makes it worthwhile. Keeping it on Incus indefinitely is fine and is what
defers Phase 9.

**Follow-up:** correct the `microvm-inventory.md` trista entry to match the
authoritative role above.

## Phase 9 — decommission Incus (if/when appropriate)

Once dev environments are in the cluster and trista's role is resolved:

- If trista was the only remaining Incus guest, remove `common.incus` from
  **calvard** (`hosts/calvard/incus/`) and **erebonia**
  (`hosts/erebonia/incus/`).
- Optionally retire `modules/incus/`, `modules/common/incus.nix`, and the
  `incus-vm` / `incus-container` checks + `mk-incus-vm` / `mk-incus-container`
  builders in `flake.nix` if nothing else uses them.
- Reclaim the Incus storage pool space.
- The flake loses one control-plane module — the report's endgame
  (NixOS + microvm.nix + k8s; 3 control planes instead of 4).

**Phase 9 may be deferred indefinitely** if trista is kept on Incus or a
new Incus use case emerges.

## Open decisions

- edith's network placement after migration: keep the lab-VLAN identity
  (`10.97.21.42`) routed into the cluster, or give it a cluster-zone
  address? Affects router6 rules and the registry entry.
- trista: leave alone (default) vs assign a concrete role now.
- Whether to fully remove the Incus module/builders in Phase 9 or just
  disable on the hosts.
