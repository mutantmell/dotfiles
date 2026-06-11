# Incus Workstation Migration Plan (edith + trista → KubeVirt, Incus sunset)

Status: Planned (not started)

**Scope:** this plan is **only** about migrating the two existing
**fully-fledged, long-lived NixOS workstations** — `edith` (the operator's
daily driver) and `trista` — off the Incus substrate onto KubeVirt VMs, and
then sunsetting Incus. These are mutable operator environments where the
operator runs things; they are **not** the ephemeral, locked-down AI coding
sandboxes.

> Not to be confused with **`ai-dev-machine-kubevirt-plan.md`** — that plan
> covers _ephemeral, locked-down dev machines for LLM agents_ (push-to-a-branch,
> no homelab reach). It shares **only** the KubeVirt platform component with
> this plan (see that plan's Phase 1 and this plan's Phase 7.1); coordinate
> which lands the platform HelmChart first.

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 7–9**.

Depends on:

- `llm-notes/done/k3s-cluster-bootstrap-plan.md` (the cluster). **Note:
  networked storage is _not_ provided by bootstrap** — it's deferred there
  (bootstrap uses local-path). **This plan stands up the liberl iSCSI
  target + democratic-csi + external-snapshotter** (bootstrap section D),
  because KubeVirt DataVolumes are the first workload that wants
  VolumeSnapshots + NAS durability. See "Phase 6.5" below.
- **Cluster proven by the AI coding layer first.** The shakedown workload
  is `k3s-cluster-workloads-plan.md` **Phase A** — on-demand dev containers
  via **DevPod** (off-the-shelf, recommended; the cc-sandbox successor). It runs before
  this migration and exercises the cluster (scheduling, isolation runtimes,
  local-path storage, OIDC) at low stakes, so the daily-driver edith doesn't
  move until the cluster has run something real for a while. (The report gated
  this on its Phases 2–4 + ~3 months of operation; the "let it run a while
  first" intent holds — the specific proving workload is now Phase A.)

Relates to / eventually obsoletes:

- **`llm-notes/done/incus-vm-migration.md`** — converted `edith` to an
  Incus VM and documented the host-side-build + `nixos-rebuild
--target-host` update model. That model carries forward conceptually;
  the Incus _substrate_ is what this plan replaces.
- **`llm-notes/done/incus-module-overhaul.md`** — the `modules/incus/` +
  `modules/common/incus.nix` work this plan eventually removes from
  calvard/erebonia (Phase 9).
- **`llm-notes/done/kata-cloud-hypervisor-migration.md`** — documents _why_
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

KubeVirt expresses these workloads directly (they _are_ VMs), keeps NixOS
as the guest OS without contortions, and maps CSI VolumeSnapshot cleanly
onto the `incus snapshot` workflow both have today. The cost
(kubevirt-operator + virt-handler DaemonSet + CRDs, ~150 MB) is real and is
the rejected alternative's tax to avoid.

> **Deviation from the report.** Report v20 kept trista as a _Pod_
> candidate (treating it as a bastion/task-runner), with KubeVirt reserved
> for edith. The operator has since clarified trista is a NixOS workstation
> just like edith, so it gets the **same KubeVirt treatment**. Phase 8 is
> rewritten accordingly.

## Guest management model — two control planes (resolved 2026-06-11)

Picking KubeVirt settles the *substrate*; it does not settle **how the
workstation's NixOS system state is managed**. The finding from the
guest-management research (this section is its landing point) is to split
management into **two control planes that are never conflated** — the
community pattern for a pet NixOS VM on Kubernetes (cf. ryan4yin's nix-config,
which does the same split):

- **Plane 1 — the VM shell ("hardware"): Flux.** Flux reconciles the
  `VirtualMachine` + `DataVolume` CRs (existence, CPU/mem, disks, NICs,
  run-state). "Long-lived" is the *declaration*; **availability is a per-host
  `runStrategy` knob** — a workstation can be declared but stopped-when-idle
  and started on demand and still be fully Flux-managed (the one lever that
  reconciles the pet shape with power cost, since the cluster host itself never
  deep-idles under k3s anyway).
- **Plane 2 — the guest OS ("software"): comin (pull), in the VM.** A
  NixOS-native **pull** reconciler runs *inside* the VM and converges its
  system closure from git, **decoupled from any host rebuild**. This is the
  whole point of the migration: it breaks today's "guest updated alongside the
  host" coupling (the `incus exec` + `switch-to-configuration` push from the
  parent in `modules/incus/default.nix`). Flux **never** reaches inside the VM;
  comin **never** touches the VM resource.

**Why comin (pull) for workstations specifically:**

- comin's one real weakness is polling (periodic wakeups → power), which is why
  it was previously rejected. For a **cluster-hosted** guest that objection is
  largely moot: erebonia under k3s is a continuous reconcile loop (kubelet,
  flannel/kube-router, virt-handler, Flux), so the host never settles into deep
  C-states regardless — a guest's git poll is marginal on top. **Tune the comin
  interval up (≈5–15 min)** since a pet workstation has no deploy-latency
  pressure.
- comin can substitute from **zeiss/Attic** like any `nixos-rebuild`, so
  "Attic-backed" is not exclusive to the fleet system; the only real difference
  is comin evaluates the flake on the host (fine — trista is resourced) vs. the
  coordinator downloading a pre-built signed closure.
- **The fleet-activation coordinator (`specs/cicd-fleet-management.md`) is the
  WRONG tool here.** Its differentiating value props — dual-signed *trusted
  images*, *network-safe activation*, *no-local-build for underpowered hosts*,
  *outbound-only as a hard requirement* — all target **infra hosts**
  (thebeyond / liberl / erebonia). trista is a resourced workstation that is
  already an inbound SSH target; **none** of those core motivations apply to it.
  The coordinator and comin are tuned for opposite ends of the host spectrum,
  not competitors for this workload.
- **Interim/fallback before comin is wired: `deploy-rs`** (push, already in the
  flake, magic rollback). Zero host polling; the tradeoff is it needs an inbound
  push path, so it's a bridge, not the endpoint.

**Scoping rule that falls out (record it so it isn't misapplied):**

- **Long-lived workstations (trista / edith) → comin (pull).**
- **Infra hosts (thebeyond / liberl / erebonia) → fleet coordinator
  (event-driven, Attic-signed).** Different host class, different tool.
- **Ephemeral AI dev sandboxes → already solved**
  (`done/ai-dev-machine-kubevirt-plan.md`: imperative per-session
  `kubectl apply`, containerDisk, **no** persistent guest plane by design).
- The general rule: **ephemeral → imperative; long-lived pet → declarative,
  committed, Flux-reconciled.** Same repo, two postures keyed on lifecycle.

**home-manager composes cleanly:** comin owns the **system** closure; users'
own `home-manager switch` (the "users manage their own state" shape) stays
their concern, entirely outside the fleet/comin plane.

## Decision #4 (Flux GitRepository source) — resolved: monorepo (2026-06-11)

The `k3s-cluster-bootstrap` / `flux.nix` open decision #4 (monorepo path vs.
separate repo for Flux's source, and the repo URL/auth) is **resolved to the
monorepo**: Flux's `GitRepository` points at **this repo** (the dotfiles flake
on creil), with manifests under a watched path here. Rationale:

- comin already makes this repo the source of truth for the **guest** plane;
  putting the **shell** plane here too means the whole workstation (VM + OS) is
  defined in one place, changed in one commit, reviewed in one PR, gated by the
  existing `run-checks.sh` + AGit flow.
- The repo is **already** the platform source of truth (cert-manager, kyverno,
  kubevirt, flux itself are HelmCharts declared here) — the dynamic layer
  landing here is consistent, not a new pattern.
- It unifies **three reconcilers on one repo + PR/CI gate**: Flux (VM shells),
  comin (guest OS), and normal host deploys.

Resolved sub-points and the one still open:

- **Manifest authoring — hand-written YAML/Kustomize *for now*; migrate to
  Nix-generated once CI is in place.** Flux reads *committed* YAML, not Nix, so
  Nix-generated manifests (precedent: the dev-machine plan authors KubeVirt VM
  specs as Nix attrsets → `toJSON`) require a **render-and-commit step that CI
  will own**. Hand-writing gets Flux reconciling with zero new machinery; the
  generation step is deferred to CI. *(This is the only remaining open
  sub-decision, and it is intentionally gated on CI.)*
- **Flux read-auth:** a read-only deploy key / token on creil for this repo. In
  the monorepo it scopes to the whole repo rather than a manifests-only subset —
  acceptable blast radius for a single-operator homelab.
- **Not yet wired:** resolving #4 settles *where* the source is; the concrete
  `GitRepository` + `Kustomization` (and the read key) are still to be created —
  see `flux.nix`.

## Current edith state (repo-grounded)

- `hosts/calvard/incus/guests/edith/default.nix` — Incus **`dev` profile**,
  `parent = "br21"` (lab VLAN 21), `limits.memory = "16GB"`,
  `limits.disk = "100GB"`, normal user `mutantmell`, eternal-terminal.
- Registry: `edith = 42` → `10.97.21.42`, lab zone
  (`lib/common/data/network.nix:78`; the comment says "calvard Incus
  container" — stale, it's a `dev`-profile guest).
- **Lives on calvard today**; the KubeVirt VM lands on **erebonia** (the
  cluster host) → this is a cross-host migration.

## Phase 6.5 — stand up networked storage (CSI), deferred from bootstrap

KubeVirt DataVolumes want VolumeSnapshots (mapping onto `incus snapshot`)
and NAS-backed durability, which `local-path-provisioner` can't provide —
so this is the phase that does the iSCSI/CSI work the bootstrap plan
deferred (its section D). Do this before the first KubeVirt VM:

- liberl iSCSI target (LIO/targetcli or scstadmin) + dedicated ZFS dataset
  hierarchy on the `data` pool + service user with
  `zfs allow create,destroy,snapshot,clone`; management endpoint (SSH/HTTP)
  for democratic-csi, credentials in sops.
- `external-snapshotter` then `democratic-csi` (`zfs-generic-iscsi`,
  targeting liberl) as HelmCharts in the k3s server manifests directory
  (`/var/lib/rancher/k3s/server/manifests/` on erebonia); `pkgs.openiscsi`
  on erebonia.
- router6 cluster-zone forward rules: cluster → liberl TCP/3260 (iSCSI) +
  SSH/HTTP mgmt endpoint (add to the zone defined in bootstrap E).
- Validate the full lifecycle (provision → bind → snapshot → restore →
  delete) against the real liberl before betting edith on it.

(If game servers — `k3s-cluster-workloads-plan.md` Phase 3 — happen to land
before this migration, they stand up CSI instead and this phase just
verifies it's present.)

## Phase 7 — migrate edith into the cluster as a KubeVirt VM

1. **KubeVirt platform — depend on it, don't re-land it.** The kubevirt-operator
   - virt-handler HelmChart is **owned by
     `llm-notes/done/ai-dev-machine-kubevirt-plan.md`** (which lands it first on
     disposable dev-machine VMs to de-risk this daily-driver move). This phase
     assumes the platform is present and adds only what edith needs on top:
     `DataVolume` support (the CDI / containerized-data-importer component, beyond
     the dev-machine containerDisk path) for the liberl-backed boot disk. If for
     some reason this migration runs first, land the platform HelmChart here
     instead — pinned, declared in the flake, reversible (revert and edith stays
     on Incus).
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

- **Ordering vs edith is an operator choice.** The AI coding layer
  (Phase A) is the cluster shakedown, so KubeVirt itself is the only
  unproven piece by the time these run. Two defensible orders:
  _edith-first_ (prioritize the daily driver — the whole point of the
  migration — with trista as the confidence-builder before Incus sunset),
  or _trista-first_ (prove the KubeVirt VM path on the lower-stakes
  secondary workstation before risking the daily driver). Either way both
  land before Phase 9.
- **DMZ placement carries over cleanly; wg-ba must be rebuilt, not carried
  over.** A KubeVirt VM is host-shaped, so it can hold a wg-ba WireGuard peer
  natively (this was the awkward part of the rejected Pod approach). **Update
  (2026-06-03):** the old router-terminated wg-ba (thebeyond `ba-tunnel` zone +
  SSH DNAT to trista) has been **removed** — see
  `wg-ba-liberl-backup-tunnel-plan.md` Phase 0 (commit `7358bcf`). trista holds
  no wg peer of its own today, so there is nothing to "carry over via router6":
  when migrated, give trista its **own direct per-host wg tunnel**, following the
  liberl pattern (`hosts/liberl/wg-ba.nix`: wg-quick + sops-templated `.conf` +
  tunnel-scoped nftables egress). Bridge the VM into the cluster CNI on the DMZ
  zone; SSH reaches trista directly over that tunnel (no router6 DNAT).
- Cutover mirrors edith: `incus export` the Incus trista → import as a
  DataVolume; parallel-run; keep the stopped Incus declaration as the
  rollback window; remove once confident.

**No urgency on timing** — trista is low-churn. But the _shape_ is settled:
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
