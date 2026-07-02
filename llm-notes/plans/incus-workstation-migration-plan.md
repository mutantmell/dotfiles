# Incus Workstation Migration Plan (edith + trista → KubeVirt, Incus sunset)

Status: Planned (not started for edith/trista migration). The prerequisite
KubeVirt/dev-machine shakedown on erebonia has landed, but this plan's
workstation migration deliverables have not. `edith` and `trista` are still
Incus guests, there are no substrate-neutral `nixosConfigurations.edith` /
`nixosConfigurations.trista` replacements, no calvard standalone
k3s/KubeVirt/Flux path for edith, and no liberl-backed CSI storage layer for
persistent workstation VM disks.

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
> which lands the platform manifests first.

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20),
**Phases 7–9**.

Depends on:

- `llm-notes/done/k3s-cluster-bootstrap-plan.md` (the cluster). **Note:
  networked storage is _not_ provided by bootstrap** — it's deferred there
  (bootstrap uses local-path). **This plan stands up the liberl iSCSI
  target + democratic-csi + external-snapshotter** (bootstrap section D),
  because KubeVirt DataVolumes are the first workload that wants
  VolumeSnapshots + NAS durability. See "Phase 6.5" below.
- **KubeVirt proven by the AI coding layer first.** The shakedown workload is
  `k3s-cluster-workloads-plan.md` **Phase A** — on-demand dev containers via
  **DevPod** (off-the-shelf, recommended; the cc-sandbox successor). It runs
  before this migration and exercises the first KubeVirt/k3s host at low stakes
  (scheduling, isolation runtimes, local-path storage, OIDC), so the daily-driver
  edith does not move until the substrate has run something real for a while.
  The report gated this on its Phases 2–4 + ~3 months of operation; the "let it
  run a while first" intent holds even though edith now stays on calvard rather
  than moving to erebonia.

Relates to / eventually obsoletes:

- The now-deleted historical Incus VM migration plan — converted `edith` to an
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

Helm/add-on ownership update (2026-06-13): this plan follows
`llm-notes/reports/k3s-flux-helm-ownership.md`. NixOS/k3s bootstraps the host
cluster and Flux only; Flux owns long-running Kubernetes desired state and Helm
releases after bootstrap; Nix owns dependency pins, rendering, and
validation. The ownership report now generalizes this into a cluster dependency
registry for Helm charts, raw upstream manifests, Flux bootstrap artifacts, and
important controller images. Flux itself is the single bootstrap exception and
should be Nix-pinned/generated into `services.k3s.manifests`; CSI, snapshotter,
CDI, KubeVirt, and related add-ons added for this migration should use the
Flux-managed path unless they are strictly needed to bootstrap Flux. Keep
Flux-owned YAML committed and reviewable, even when Nix renders or validates it.

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

## Guest management model — hybrid ownership (resolved 2026-06-13)

Picking KubeVirt settles the *substrate*; it does not settle **who owns which
part of the workstation lifecycle**. The settled model is a **hybrid**:

- **Steady-state VM shell ("hardware"): Flux.** Flux reconciles the long-lived
  Kubernetes objects: namespace, network attachment references, stable PVC
  references, `VirtualMachine`, snapshot policy, CPU/memory, disks, NICs, and
  run-state. "Long-lived" is the declaration; **availability is a per-host
  `runStrategy` knob**. A workstation can be declared, stopped-when-idle, and
  started on demand while still being Flux-managed.
- **Imperative provisioning and migration: a narrow operator-side tool.** A
  small `workstation-provision` script/app owns the steps that are not good
  GitOps fits: importing an Incus export or flake-built qcow2 into a PVC,
  seeding private bootstrap files from passage, stopping/starting around disk
  mutation, running validation, and doing restore drills. This is similar in
  spirit to the dev-machine launcher, but deliberately **not** the long-term
  owner of the workstation.
- **Guest OS ("software"): comin (pull), in the VM.** A NixOS-native **pull**
  reconciler runs *inside* the VM and converges its system closure from git,
  **decoupled from any host rebuild**. This is the whole point of the migration:
  it breaks today's "guest updated alongside the host" coupling (the `incus exec`
  + `switch-to-configuration` push from the parent in
  `modules/incus/default.nix`).
- **Bootstrap secret authority: passage.** passage remains the operator-side
  authority for the one secret that cannot live in git: the guest's sops-nix
  age identity. Flux and Kubernetes never become a standing decryption root for
  the guest.

Strict ownership rule:

- Flux never reaches inside the guest and never sees private guest bootstrap
  material.
- comin never creates, deletes, or mutates the KubeVirt VM resource.
- `workstation-provision` handles one-time and break-glass imperative actions,
  then exits; it does not continuously reconcile.
- passage owns private bootstrap identities; sops-nix owns ordinary in-guest
  secret decryption after activation.

**Why comin (pull) for workstations specifically:**

- comin's one real weakness is polling (periodic wakeups → power), which is why
  it was previously rejected. For a **KubeVirt-hosted** guest that objection is
  largely moot: k3s, kubelet, flannel/kube-router,
  virt-handler, and Flux are already continuous reconcile loops, so the host
  never settles into deep C-states regardless. A guest's git poll is marginal on
  top. **Tune the comin interval up (≈5–15 min)** since a pet workstation has no
  deploy-latency pressure.
- comin can substitute from **zeiss/Attic** like any `nixos-rebuild`, so
  "Attic-backed" is not exclusive to the fleet system; the only real difference
  is comin evaluates the flake on the host (fine — trista is resourced) vs. the
  coordinator downloading a pre-built signed closure.
- **The fleet-activation layer (`specs/cicd-fleet-management.md` — its
  *per-host* event-driven coordinators; a *central* coordinator is an explicit
  non-goal there) is the WRONG tool here.** Its differentiating value props —
  dual-signed *trusted
  images*, *network-safe activation*, *no-local-build for underpowered hosts*,
  *outbound-only as a hard requirement* — all target **infra hosts**
  (thebeyond / liberl / erebonia). trista is a resourced workstation that is
  already an inbound SSH target; **none** of those core motivations apply to it.
  The coordinator and comin are tuned for opposite ends of the host spectrum,
  not competitors for this workload.
- **Interim/fallback before comin is wired: `deploy-rs`** (push, already in the
  flake, magic rollback). Zero host polling; the tradeoff is it needs an inbound
  push path, so it's a bridge, not the endpoint.
- **Comin implementation requirements:** pin comin as an explicit flake input
  or package source; test Forgejo/creil auth before migration; set
  `services.comin.hostname` explicitly; consider commit signature checking;
  use `machineId` during migration so old and new VMs cannot both converge the
  same host unintentionally; configure zeiss/Attic substituters and trusted keys;
  tune the poll interval to roughly 10-15 minutes.

**Scoping rule that falls out (record it so it isn't misapplied):**

- **Long-lived workstations (trista / edith) → comin (pull).**
- **Migration/provisioning of those workstations → `workstation-provision`
  one-shot tool, not Flux and not comin.**
- **Infra hosts (thebeyond / liberl / erebonia) → the cicd-fleet activation
  layer (per-host event-driven coordinators, Attic-signed).** Different host
  class, different tool.
- **Ephemeral AI dev sandboxes → already solved**
  (`done/ai-dev-machine-kubevirt-plan.md`: imperative per-session
  `kubectl apply`, containerDisk, **no** persistent guest plane by design).
- The general rule: **ephemeral → imperative; long-lived pet → declarative
  steady state with imperative provisioning.** Same repo, different posture by
  lifecycle phase.

**home-manager composes cleanly:** comin owns the **system** closure; users'
own `home-manager switch` (the "users manage their own state" shape) stays
their concern, entirely outside the fleet/comin plane.

## Decision #4 (Flux GitRepository source) — resolved: monorepo (2026-06-11)

The `k3s-cluster-bootstrap` / `flux.nix` open decision #4 (monorepo path vs.
separate repo for Flux's source, and the repo URL/auth) is **resolved to the
monorepo**: each KubeVirt/k3s host's Flux instance points at **this repo** (the
dotfiles flake on creil), with manifests under watched per-host paths here.
Rationale:

- comin already makes this repo the source of truth for the **guest** plane;
  putting the **shell** plane here too means the whole workstation (VM + OS) is
  defined in one place, changed in one commit, reviewed in one PR, gated by the
  repo PR/CI flow. Today that means `run-checks.sh` plus AGit; the target agent
  workflow is the validated normal-branch + `tea` path described in
  `llm-notes/done/agent-ci-readonly-woodpecker-plan.md`.
- The repo is **already** the platform source of truth, but the ownership
  boundary is now explicit: k3s/NixOS bootstraps Flux, Flux reconciles the
  long-running Kubernetes objects and Helm releases, and Nix pins/renders/
  validates dependency inputs (see
  `llm-notes/reports/k3s-flux-helm-ownership.md`). The dynamic layer landing
  here is consistent, not a new pattern.
- It unifies the declarative surfaces behind one repo + PR/CI gate: Flux (VM
  shells), comin (guest OS), and normal host deploys. The imperative
  `workstation-provision` tool consumes this repo and passage, but does not add
  another continuously reconciling state source.

Resolved sub-points and the one still open:

- **Manifest authoring — hand-written YAML/Kustomize *for now*; migrate to
  Nix-generated once CI is in place.** Flux reads *committed* YAML, not Nix, so
  Nix-generated manifests (precedent: the dev-machine plan authors KubeVirt VM
  specs as Nix attrsets → `toJSON`) require a **render-and-commit step that CI
  will own**. Hand-writing gets Flux reconciling with zero new machinery; the
  generation step is deferred to CI. *(This is the only remaining open
  sub-decision, and it is intentionally gated on CI.)* The dependency-update
  model should still be settled before broad migration: either the Nix registry
  is authoritative and an updater edits it before regenerating YAML, or the
  committed Flux YAML is authoritative and Nix validates/fetches from it. Avoid
  a mixed model where update automation edits only generated YAML while Nix owns
  separate version fields.
- **Flux read-auth:** a read-only deploy key / token on creil for this repo. In
  the monorepo it scopes to the whole repo rather than a manifests-only subset —
  acceptable blast radius for a single-operator homelab.
- **Not yet wired:** resolving #4 settles *where* the source is; the concrete
  `GitRepository` + per-host `Kustomization`s (and the read key) are still to be
  created — see `flux.nix`. erebonia already owns the cluster/dev-machine
  KubeVirt path; calvard needs its own non-clustered k3s/Flux/KubeVirt platform
  path before edith moves.
- **Provisioning tool is not the source of truth.** If it needs to create a
  temporary importer pod/job or upload server, those resources are operational
  scaffolding and should be deleted after the import/seed step. The durable
  desired state remains the committed Flux manifest plus the guest's
  `nixosConfigurations.<host>` output.

## Secrets & key bootstrap across the migration (resolved 2026-06-11)

The migration must not disturb the trust model, which is more than "sops-nix +
age." Current model, grounded in the repo:

- **sops-nix with native hybrid post-quantum age** (upstream age ≥ 1.3.0 —
  recipients `age1pq1…`, identities `AGE-SECRET-KEY-PQ-1…`, generated by
  `age-keygen -pq`, **no plugin**). Secrets are encrypted at rest in git and
  decrypted to tmpfs at activation. age refuses mixed classical+PQC recipients,
  so the recipient set is fully PQC.
- **passage** is the operator-side authority for private keys (SSH host keys,
  the PQC age identities, the SSH CA, fleet-enrollment, x5c).
- **`setup-guest.sh`** is the bootstrap tool: per guest it pulls-or-generates
  the PQC age identity, stores it in passage, and **plants it onto the guest's
  persisted `/static` tree** at `var/lib/sops-nix/key.txt`; the guest's
  `sops.nix` reads it via `age.keyFile`. On Incus that tree reaches the guest
  via a **virtiofs `/static` share**.
- Bootstrap chain: **passage → `setup-guest.sh` plants the PQC age key
  out-of-band → in-guest sops-nix decrypts everything else.** The age key is the
  one secret that cannot live in git; it is delivered out-of-band.

**What changes on KubeVirt — only the delivery vehicle, not the trust model.**
Replace the Incus virtiofs `/static` share with an **offline-seeded KubeVirt
disk/PVC path**. `setup-guest.sh --output-dir` already emits the planted tree;
`workstation-provision` retargets that output into the VM's disk or a small
static PVC while the VM is stopped, using libguestfs/guestfish/virt-customize or
a one-shot Kubernetes job that attaches the PVC. The guest `sops.nix` still
reads `/static/var/lib/sops-nix/key.txt`; Flux declares the VM and PVC
references but never sees the key plaintext.

Explicitly **do not** use cloud-init, `configDrive`, KubeVirt Secret volumes, or
Flux SOPS for the guest's PQC age identity. Those mechanisms are useful
KubeVirt/Kubernetes tools, but they place plaintext or a standing decryption
root inside the cluster. They are acceptable for public or low-sensitivity
shell-plane data, not for the root guest decryption identity.

**Flux SOPS — feasible, but NOT used for the sops / PQC-age root.**

- **Capability (verified 2026-06-11):** Flux's kustomize-controller *can*
  decrypt the hybrid-PQC age sops secrets natively — its current `go.mod`
  vendors `getsops/sops v3.13.1` + `filippo.io/age v1.3.1` (PQC native since age
  1.3.0). No `age-plugin-pq`, no custom controller image. (An earlier "Flux
  can't decrypt PQC age" assessment was **wrong** — that was only true for sops
  ≤ 3.11 / age ≤ 1.2.1.)
- **Caveat to confirm before relying on it:** the pinned Flux bootstrap version
  must install a kustomize-controller image recent enough to bundle sops ≥ 3.12 /
  age ≥ 1.3.1 — verify the Flux-version → controller-image mapping (the upstream
  capability is unambiguous; the pinned image is the only unknown).
- **Decision — keep passage/sops-nix for the guest root anyway.** This is now a
  judgment call, *not* a technical limit:
  - Flux SOPS needs its own in-cluster `sops-age` identity (a Secret in
    `flux-system`) added as a recipient on guest bootstrap keys → a second
    standing decryption root the cluster holds (blast-radius expansion; today
    only passage holds these).
  - It re-couples the most sensitive bit — the bootstrap identity — to
    cluster/Flux health, against the guest-plane decoupling chosen above.
  - It crosses the passage(operator) / sops-nix(service) boundary the
    cicd-fleet spec defines.

**Where Flux / k8s Secrets ARE the right tool — shell-plane only:** KubeVirt
**AccessCredentials** SSH *public* keys (public — no secrecy), a registry pull
secret for a temporary DataVolume image source, a cloud-init network seed. The
split mirrors the hybrid ownership model: **Flux/k8s Secrets for shell-plane
public/cluster-scoped material; passage + `setup-guest.sh` + sops-nix (PQC age)
for the guest's actual secrets.** The guest's secret bootstrap is unchanged by
the migration — only the `/static` delivery vehicle swaps from virtiofs to a
KubeVirt volume.

**vTPM decision — defer.** KubeVirt persistent vTPM is useful for TPM-backed
LUKS unlock, measured boot, Secure Boot/UKI work, or Windows/BitLocker-style
requirements. For this migration it would only add a second layer around
already-seeded guest secrets, while also adding persistent backend-state PVCs
and restore/clone constraints. Do not enable vTPM for edith/trista initially.
Revisit only if the plan grows a concrete TPM-backed disk or boot-hardening
goal. If enabled later, it protects secrets at rest inside the guest; it is not
the initial injection path from passage.

## Current edith state (repo-grounded)

- `hosts/calvard/incus/guests/edith/default.nix` — Incus **`dev` profile**,
  `parent = "br21"` (lab VLAN 21), `limits.memory = "16GB"`,
  `limits.disk = "100GB"`, normal user `mutantmell`, eternal-terminal.
- Registry: `edith = 42` → `10.97.21.42`, lab zone
  (`lib/common/data/network.nix:78`; the comment says "calvard Incus
  container" — stale, it's a `dev`-profile guest).
- **Lives on calvard today**; the KubeVirt VM stays on **calvard**. This avoids
  turning edith into a cross-host migration, but requires calvard to become a
  standalone, non-clustered k3s/KubeVirt host first.

## Phase 6.4 — host placement and bridge-free VM networking

The placement decision is now settled:

- **edith stays on calvard.** calvard becomes a standalone, non-clustered k3s
  host with KubeVirt/Flux/CDI/CSI enough to run the edith workstation VM. It does
  not join the erebonia cluster.
- **trista stays on erebonia.** erebonia remains the first KubeVirt/k3s host for
  dev-machine and trista.

Before either workstation moves, migrate host-side guest networking away from
Linux bridges and toward macvlan/macvtap-compatible lower devices on both
calvard and erebonia:

- Replace bridge-backed guest VLAN attachment (`br*` + tap enslaving) with
  standalone VLAN lower devices (`uplink.<vlan>` / equivalent) used by
  macvtap/macvlan. This applies to both KubeVirt VMs and existing microVMs.
- Keep host management IPs on the host's own management VLAN/interface; guest
  VLAN lower devices should generally be host-IP-less carriers.
- Preserve the current routed identities: edith on lab VLAN 21
  (`10.97.21.42`), trista on DMZ/VLAN 100, and existing microVM guest VLANs.
- Extend the already-proven VLAN-51 macvtap approach into reusable host
  networking patterns for VLAN 11/21/50/100 as needed, rather than maintaining
  per-host bridge special cases.
- Validate host↔guest, routed-in, DHCP/static addressing, firewall, and
  observability paths after each VLAN conversion. This is a prerequisite because
  k3s forces bridge netfilter settings that made bridge-backed VM networking a
  proven bad fit for routed guest traffic.

## Phase 6.5 — stand up networked storage (CSI), deferred from bootstrap

KubeVirt DataVolumes want VolumeSnapshots (mapping onto `incus snapshot`)
and NAS-backed durability, which `local-path-provisioner` can't provide —
so this is the phase that does the iSCSI/CSI work the bootstrap plan
deferred (its section D). Do this before the first persistent KubeVirt
workstation VM on either host:

- liberl iSCSI target (LIO/targetcli or scstadmin) + dedicated ZFS dataset
  hierarchy on the `data` pool + service user with
  `zfs allow create,destroy,snapshot,clone`; management endpoint (SSH/HTTP)
  for democratic-csi, credentials in sops.
- `external-snapshotter` then `democratic-csi` (`zfs-generic-iscsi`,
  targeting liberl) on each KubeVirt host that needs durable VM disks: erebonia
  for trista/dev-machine paths, and calvard for edith. Install as Flux-managed
  cluster desired state for each host, with Nix-owned chart/manifest pins and
  validation through the cluster dependency registry; add `pkgs.openiscsi` on
  both hosts.
- router6 forward rules: each KubeVirt host zone → liberl TCP/3260 (iSCSI) +
  SSH/HTTP mgmt endpoint. Do not assume only the erebonia cluster zone needs
  this path.
- Validate the full lifecycle (provision → bind → snapshot → restore →
  delete) against the real liberl before betting either workstation on it.

(If game servers — `k3s-cluster-workloads-plan.md` Phase 3 — happen to land
before this migration, they stand up CSI instead and this phase just
verifies it's present.)

## Phase 6.6 — make workstations substrate-neutral before moving them

Do this while edith/trista still run on Incus, so the NixOS system definition is
separated from the Incus substrate before KubeVirt enters the picture:

- Move the reusable guest system definitions out of
  `hosts/*/incus/guests/<name>/default.nix` into substrate-neutral workstation
  modules exposed as `nixosConfigurations.edith` and
  `nixosConfigurations.trista`.
- Keep temporary Incus wrappers that import those workstation modules plus
  `incus-guest`, `modules/incus/disko-virtual-machine.nix`, and the Incus disko
  image profile until cutover is complete.
- Add a KubeVirt guest profile for the new VM image path: qemu guest support,
  serial console, growfs, qemu-guest-agent, comin, Attic substituters, and the
  `/static` mount/path expected by sops-nix. Do **not** carry
  `virtualisation.incus.agent` or Incus metadata assumptions into KubeVirt.
- Add flake outputs/checks that can build:
  - the normal NixOS system closure for comin/deploy-rs;
  - a first-boot qcow2/raw image for DataVolume import or disaster recovery.
- Extend `setup-guest.sh` or add `workstation-provision` so it can discover
  substrate-neutral workstation names, generate/reuse passage identities, and
  emit a seed tree suitable for a KubeVirt PVC/disk.

The desired end state is: "edith" and "trista" are normal NixOS hosts in the
flake; Incus and KubeVirt are wrappers around that host definition, not the place
where the host identity lives.

## Phase 7 — migrate edith on calvard as a KubeVirt VM

1. **KubeVirt platform — reuse the pattern, but land it on calvard.** The
   upstream KubeVirt operator manifest + singleton `KubeVirt` CR pattern is
   owned first by `llm-notes/done/ai-dev-machine-kubevirt-plan.md` on erebonia.
   Edith uses the same pinned upstream-manifest approach, but on calvard's own
   standalone, non-clustered k3s host. Add only what edith needs on top:
   `DataVolume` support (the CDI / containerized-data-importer component) for
   the liberl-backed boot disk. Install CDI the same way: pinned upstream CDI
   operator/CR manifests or an explicitly selected maintained packaging path,
   declared through the Flux-managed cluster path, pinned/validated by Nix, and
   reversible. If using raw upstream manifests rather than a chart, track the
   release URL/version/hash in the same cluster dependency registry used for
   Helm charts and Flux bootstrap.
2. **Build the edith VM image** from the flake: a pre-built NixOS disk
   image (qcow2/raw) via `nixos-generators` or the flake-native
   equivalent, reproducible across rebuilds. (cloud-init into a blank
   DataVolume is a valid alternate install path, but flake-built image is
   the canonical "infrastructure is text in git" pattern.)
3. **Provision/import the mutable root disk with `workstation-provision`:**
   - For migration, prefer importing the real Incus disk/export into a
     liberl-backed PVC so mutable workstation state comes across.
   - For fresh install or disaster recovery, import the flake-built qcow2/raw
     image into a DataVolume/PVC.
   - Treat DataVolume import as a **one-time creation path**. After first boot,
     the boot PVC is mutable workstation state and must not be overwritten by
     subsequent image rebuilds. Normal OS updates happen through comin.
   - Seed `/static/var/lib/sops-nix/key.txt` and SSH host keys into the stopped
     VM disk/static PVC from passage-generated output. Delete any temporary
     importer/seed jobs after the PVC is ready.
4. **Define the calvard Flux-owned `VirtualMachine` resource:**
   - CPU/memory matching today's allocation (16 GB per the Incus config).
   - Boot disk PVC on **democratic-csi** (liberl backing); VolumeSnapshot for
     periodic backups.
   - Preserve edith's lab identity by attaching the VM to VLAN 21 with
     Multus/macvtap on calvard, following the bridge-free host networking
     pattern from Phase 6.4 rather than ordinary pod CNI. Today calvard uses
     `enp88s0.21` + `br21`; before creating the NAD, split out a dedicated
     VLAN-21 macvtap carrier or otherwise make the host networking compatible.
     Add the calvard VLAN-21 macvtap device-plugin exposure + NAD and keep the
     network registry address stable (`10.97.21.42`).
   - Use KubeVirt AccessCredentials for SSH public keys if helpful; keep private
     bootstrap secrets out of Kubernetes.
5. **Cutover:**
   - Parallel-run a few weeks: validate builds, dev workflows, sshd
     access, the langport routing chain, and VolumeSnapshot backup/restore.
   - Cut over by switching DNS / langport routing to the new edith. Keep
     the **Incus edith declared but stopped** for several more weeks as
     rollback; remove the Incus declaration once confidence is high.

edith is the operator's daily driver — the parallel-run + stopped-Incus
rollback window is the mitigation for that risk.

## Phase 8 — migrate trista on erebonia as a KubeVirt VM

**Authoritative role (operator, 2026-06-01):** trista is a **fully-fledged
NixOS workstation, the same shape as edith** — accessed as an SSH target in
DMZ over the wg-ba mesh, and usable as a task runner. It is **not** a
bastion and **not** a container-shaped workload. This supersedes the
conflicting descriptions previously scattered across the repo:

- `lib/common/data/network.nix` — the old "SSH bastion" comment was **already
  corrected** to the NixOS-workstation role (the trista entry now reads "NixOS
  workstation / dev environment …"); observed state, not pending work for this
  plan.
- `hosts/erebonia/incus/guests/trista/default.nix` → profile **`dmz-vm`**,
  `macvlan` on `uplink.100` (DMZ placement — preserve after migration).
- `docs/hostnames.md` → the trista entry **already** reads "NixOS dev
  workstation … → KubeVirt VM" (no longer the stale "task runner (backup)"
  text); no refresh needed.
- `llm-notes/done/vlab-zone-plan.md` (vLAB) → "trista stays on DMZ, serves
  wg-ba mesh peer" — consistent.

Because trista is workstation-shaped, it migrates with the same hybrid model as
edith in Phase 7, but on erebonia: substrate-neutral
`nixosConfigurations.trista`, one-time Incus/import + passage seed through
`workstation-provision`, an erebonia Flux-owned KubeVirt `VirtualMachine`
pointing at a durable liberl-backed PVC, VolumeSnapshot backups, and comin for
steady-state guest OS updates. The "Why edith and trista are KubeVirt VMs"
reasoning above applies in full. Concretely:

- **Ordering vs edith is an operator choice.** The AI coding layer
  (Phase A) is the erebonia KubeVirt shakedown, so the KubeVirt pattern is
  proven before these workstation moves. Two defensible orders:
  _edith-first_ (prioritize the daily driver — the whole point of the
  migration — with trista as the confidence-builder before Incus sunset),
  or _trista-first_ (prove the KubeVirt VM path on the lower-stakes
  secondary workstation before risking the daily driver). Either way both land
  before Phase 9, and neither move changes physical host placement.
- **DMZ placement carries over cleanly; wg-ba must be rebuilt, not carried
  over.** A KubeVirt VM is host-shaped, so it can hold a wg-ba WireGuard peer
  natively (this was the awkward part of the rejected Pod approach). **Update
  (2026-06-03):** the old router-terminated wg-ba (thebeyond `ba-tunnel` zone +
  SSH DNAT to trista) has been **removed** — see
  `wg-ba-liberl-backup-tunnel-plan.md` Phase 0 (commit `7358bcf`). trista holds
  no wg peer of its own today, so there is nothing to "carry over via router6":
  when migrated, give trista its **own direct per-host wg tunnel**, following the
  liberl pattern (`hosts/liberl/wg-ba.nix`: wg-quick + sops-templated `.conf` +
  tunnel-scoped nftables egress). Preserve DMZ placement with Multus/macvtap on
  VLAN 100 (`uplink.100`), not ordinary pod CNI. `uplink.100` is already a
  standalone carrier on erebonia, but the cluster still needs a VLAN-100
  macvtap device-plugin exposure + NAD; current Multus wiring only exposes the
  VLAN-51 dev-machine resource. SSH reaches trista directly over that tunnel (no
  router6 DNAT).
- Cutover mirrors edith: `workstation-provision` imports the Incus trista disk
  into the durable PVC, seeds passage-managed bootstrap files while stopped,
  starts the Flux-owned VM, validates, parallel-runs, and keeps the stopped Incus
  declaration as the rollback window.

**No urgency on timing** — trista is low-churn. But the _shape_ is settled:
KubeVirt VM, not Pod. Keeping it on Incus until edith is proven is fine.

**Follow-up (already done):** the `docs/hostnames.md` trista entry already
reads its post-migration role ("NixOS dev workstation … → KubeVirt VM"); no
refresh needed.

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

- Whether to fully remove the Incus module/builders in Phase 9 or just
  disable on the hosts.

## Settled follow-ups from 2026-06-13 review

- **Steady-state ownership:** Flux owns durable KubeVirt shell objects;
  `workstation-provision` owns import/seed/validation one-shots; comin owns
  guest NixOS convergence; passage owns private bootstrap identities.
- **Secrets:** Keep manual/operator injection from passage. Do not introduce
  Vault unless future workload count, rotation/audit needs, or multi-operator
  access control justify a dedicated secret service. Kubernetes/Flux secrets are
  shell-plane only for this migration.
- **vTPM:** Defer. It is useful for TPM-backed LUKS/measured boot later, but not
  worth adding solely to wrap the sops age key after it has already been seeded.
- **Placement:** edith stays on calvard; trista stays on erebonia. calvard gets
  a standalone, non-clustered k3s/KubeVirt/Flux path for edith rather than
  joining the erebonia cluster.
- **Networking:** Preserve existing identities. edith stays lab VLAN 21
  (`10.97.21.42`); trista stays DMZ/VLAN 100 and gets a direct per-host wg-ba
  tunnel. Move KubeVirt and microVM guest networking away from Linux bridges and
  toward macvlan/macvtap-compatible lower devices on both calvard and erebonia,
  extending the existing VLAN-51 macvtap lesson into a general host networking
  pattern.
