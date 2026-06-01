# k3s Dev-Environment Migration Plan (edith + trista → KubeVirt, Incus sunset)

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
  `EBUSY`). That lesson is exactly why edith and trista go to **KubeVirt
  (real VMs)**, not Pod + PVC.

---

## Why edith and trista are KubeVirt VMs, not Pods

**Both edith and trista are fully-fledged NixOS workstations** (operator,
2026-06-01) — mutable NixOS systems with systemd as PID 1, writable store,
home-manager. The stated goal of the Incus → cluster migration is "replace
Incus with something **workstation-shaped**." Pod + PVC + systemd-as-PID-1
has two real frictions for that shape:

1. **PSS Restricted fights systemd-as-PID-1** — it blocks `/sys/fs/cgroup`
   rw and `procMount: Unmasked`, both of which systemd-as-PID-1 wants.
   Falling back to PSS Baseline is an isolation downgrade; falling back to
   a non-systemd init breaks the mutable-NixOS shape.
2. The Coder / Gitpod / Codespaces precedents are container-shaped (thin
   inits), not systemd-as-PID-1 — they don't transfer 1:1.

KubeVirt expresses these workloads directly (they *are* VMs), keeps NixOS
as the guest OS without contortions, and maps CSI VolumeSnapshot cleanly
onto the `incus snapshot` workflow both have today. The cost
(kubevirt-operator + virt-handler DaemonSet + CRDs, ~150 MB) is real and is
the rejected alternative's tax to avoid.

> **Deviation from the report.** Report v20 kept trista as a *Pod*
> candidate (treating it as a bastion/task-runner), with KubeVirt reserved
> for edith. The operator has since clarified trista is a NixOS workstation
> just like edith, so it gets the **same KubeVirt treatment**. Phase 8 is
> rewritten accordingly.

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

## Phase 8 — migrate trista into the cluster as a KubeVirt VM

**Authoritative role (operator, 2026-06-01):** trista is a **fully-fledged
NixOS workstation, the same shape as edith** — accessed as an SSH target in
DMZ over the wg-ba mesh, and usable as a task runner. It is **not** a
bastion and **not** a container-shaped workload. This supersedes the
conflicting descriptions previously scattered across the repo:

- `lib/common/data/network.nix` comment said "SSH bastion" — **corrected**
  to "NixOS workstation / dev environment" as part of this work.
- `hosts/erebonia/incus/guests/trista/default.nix` → profile **`dmz-vm`**,
  `macvlan` on `uplink.100` (DMZ placement — preserve after migration).
- `docs/hostnames.md` → "Dev environment / task runner (backup)" — stale
  (calls trista a backup task runner, not a workstation); needs refresh
  (flagged below).
- `llm-notes/done/vlab-zone-plan.md` (vLAB) → "trista stays on DMZ, serves
  wg-ba mesh peer" — consistent.

Because trista is workstation-shaped, it migrates **exactly like edith in
Phase 7**: a KubeVirt `VirtualMachine` with a flake-built NixOS image on a
DataVolume (liberl-backed CSI, VolumeSnapshot backups). The "Why edith and
trista are KubeVirt VMs" reasoning above applies in full. Concretely:

- Add it after edith is proven (edith is the daily driver and goes first);
  trista is the secondary/backup workstation, so it's the lower-risk
  second KubeVirt VM and a good confidence-builder before Incus sunset.
- **DMZ placement + wg-ba mesh peering carry over cleanly** — a KubeVirt VM
  is host-shaped, so it can hold the wg-ba WireGuard peer the same way the
  Incus VM does today; no need to terminate wg-ba elsewhere (this was the
  awkward part of the rejected Pod approach). Bridge the VM into the
  cluster CNI on the DMZ zone; route SSH/wg-ba via router6.
- Cutover mirrors edith: `incus export` the Incus trista → import as a
  DataVolume; parallel-run; keep the stopped Incus declaration as the
  rollback window; remove once confident.

**No urgency on timing** — trista is low-churn. But the *shape* is settled:
KubeVirt VM, not Pod. Keeping it on Incus until edith is proven is fine.

**Follow-up:** refresh the `docs/hostnames.md` trista entry to "NixOS
workstation (KubeVirt VM after migration)".

## Phase 9 — decommission Incus

With **both** edith (Phase 7) and trista (Phase 8) migrated to KubeVirt,
Incus has no remaining guests — edith (calvard) and trista (erebonia) are
the only two Incus guests today. So Phase 9 is now a clean removal rather
than a contingent one:

- Remove `common.incus` from **calvard** (`hosts/calvard/incus/`) and
  **erebonia** (`hosts/erebonia/incus/`).
- Retire `modules/incus/`, `modules/common/incus.nix`, and the `incus-vm` /
  `incus-container` checks + `mk-incus-vm` / `mk-incus-container` builders
  in `flake.nix` (nothing else uses them once both guests are gone — verify
  before removing).
- Reclaim the Incus storage pool space.
- The flake loses one control-plane module — the report's endgame
  (NixOS + microvm.nix + k8s; 3 control planes instead of 4).

Do this only after both KubeVirt VMs have run reliably through their
rollback windows (the stopped Incus declarations are the rollback path
until then).

## Open decisions

- Network placement after migration for **both** workstations: keep their
  current identities (edith lab VLAN `10.97.21.42`; trista DMZ + wg-ba) and
  route them into the cluster, or give them cluster-zone addresses? Affects
  router6 rules and the registry entries. trista additionally must keep its
  wg-ba mesh peer working (KubeVirt VM holds it natively).
- Whether to fully remove the Incus module/builders in Phase 9 or just
  disable on the hosts.
