# k3s Cluster Bootstrap Plan

Status: In progress (Phase 0 COMPLETE; open decisions settled; chunk 1a built &
deploying; chunks 1b/1c/2/3 pending)

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20).
This plan implements **Phase 0–1** of that report, plus the deferred
multi-node / HA topology (Phases 10–11) as a forward-looking section.

Depends on: nothing in-repo (greenfield). The Authelia migration is **done**
(`llm-notes/done/authelia-migration-plan.md`), so OIDC `kubectl` access at
bootstrap can target the live foundational Authelia — open decision #1 is now
resolved (Authelia OIDC + on-disk x509 admin kubeconfig as break-glass).

**Prerequisite — DONE: deployd is removed.** deployd has been fully
decommissioned (no remaining `.nix` references; see
`llm-notes/done/k3s-deployd-migration-plan.md`). k3s therefore lands on a
clean erebonia with **no deployd coexistence to manage** (no shared kata
config, no duplicate nested-KVM modprobe, no containerd/CNI/bridge/port
audit) — the single biggest simplification to the bootstrap, already banked.

Foundation for (recommended execution order):

1. `llm-notes/plans/k3s-cluster-workloads-plan.md` **Phase A** — AI coding
   layer: on-demand dev containers via **DevPod** (off-the-shelf,
   recommended; Coder if it goes multi-user). The **low-stakes starter and
   cluster shakedown**; the cc-sandbox-workflow successor. Uses local
   storage (no CSI needed yet).
2. `llm-notes/plans/k3s-dev-env-migration-plan.md` (edith + trista → KubeVirt,
   Incus sunset) — migrate the existing dev environments, once the cluster
   is proven by Phase A. **This is where networked storage (liberl iSCSI +
   democratic-csi) gets stood up**, since KubeVirt DataVolumes want NAS
   durability + VolumeSnapshot backups (deferred from bootstrap — see D).
3. The **rest** of `k3s-cluster-workloads-plan.md` (blog, game servers, CI)
   — remaining net-new features. Game servers also use CSI (already up).

Rationale: with deployd already gone, bootstrap on a clean host. The AI
coding layer (dev containers) is built first as a low-stakes shakedown on
local storage that proves the cluster before the daily-driver edith moves.
This reorders the report's phase numbering (it ran net-new workloads as
Phases 2–4 before the migrations).

Reverses the earlier k3s rejection that motivated deployd (the
dynamic-container-layer spec, since deleted — see the report
`llm-notes/reports/k8s-migration-evaluation.md` for the reversal). deployd
was retired in favour of this direction — see
`llm-notes/done/k3s-deployd-migration-plan.md`.

---

## Goal

Stand up a **single-node, all-bare-metal** k3s cluster on **erebonia**: one
`services.k3s` in `role = "server"` (apiserver, controller-manager,
scheduler, kine+SQLite, **and** the kubelet/containerd/CNI — the agent is
included, not disabled). All workloads run on erebonia with native hardware
access (kata-qemu, `/dev/kvm`, NUMA, native networking).

Everything platform-level is declared in this flake; a fresh
`nixos-rebuild switch` on erebonia must bring the whole platform up with
no manual `helm install` or imperative steps. Rollback is
`nixos-rebuild switch --rollback` / boot the prior generation.

Storage at bootstrap is **local only** (k3s's bundled
`local-path-provisioner` on erebonia). Networked block storage (liberl
iSCSI + democratic-csi) is **deferred** until a workload needs
VolumeSnapshots or NAS durability — see D.

### Deliberate deviation from the report: no split control plane

The report (v19/v20) recommends a **split control plane** — `k3s server`
(`--disable-agent`) inside a microvm on erebonia, with a separate `k3s
agent` on bare metal — to confine the apiserver's network exposure to a
microvm, mirroring the deployd-api (`roer`) / Authelia (`messeldam`)
pattern. **We intentionally do not do this.** For a single-node homelab
cluster the split is largely security theater at real complexity cost:

- It's half a boundary. The split isolates the apiserver from the host but
  leaves the **kubelet** (root, network-exposed on :10250, sitting right
  next to the untrusted workloads) on bare metal — the likelier compromise
  path is untouched.
- The agent holds node credentials that can drive the full kube API over
  legitimate mTLS, so **host compromise ≈ cluster compromise** regardless
  of where the apiserver runs. The microvm isn't on that path.
- The deployd analogy doesn't transfer: deployd's security came from a
  **narrow, audited vsock protocol** + privilege-dropping in the helper,
  not the microvm per se. The k3s agent↔server link is the _entire_
  Kubernetes API spoken by a credentialed kubelet — not a narrow surface to
  confine.
- The real isolation the homelab needs is **per-workload** (gVisor / kata /
  landlock, "security when needed" — the report's own runtime tiers), which
  is independent of where the control plane runs.

Net: bare-metal single-node drops the apiserver microvm, the kine-in-guest
persistence/backup problem, the `sd_notify`+oneshot bootstrap chain, and
split-reset semantics. We confine :6443 with the host firewall + router6
(network confinement doesn't need a separate kernel), and put the security
budget into the runtime tiers. The only thing given up is the clean
microvm-rebuild recovery for the control plane — replaced by routine
kine/etcd snapshot backups, which we want anyway. (HA later can still add
control-plane nodes on _other_ hosts — see "Deferred — multi-node & HA".)

## Repo-grounding corrections to the report

The report is accurate on the two load-bearing host roles (calvard =
static fleet, erebonia = dynamic) but has a few stale labels that this
plan corrects against the live repo:

- **router6 lives on `thebeyond`, not erebonia.** Zones are defined in
  `hosts/thebeyond/router.nix` (`router6.zones`, ~line 173). erebonia
  does **not** import router6. The new `cluster` zone is added to
  thebeyond's router config; erebonia's cluster traffic traverses the
  router like any other host.
- **OIDC provider is currently Keycloak (`messeldam`), not Authelia.**
  The report says "Authelia"; an Authelia migration is _planned_
  (`llm-notes/plans/authelia-migration-plan.md`) but not done. kube
  apiserver OIDC should target whichever provider is live when Phase 1
  lands. See "Open decisions".
- **Observability is VictoriaMetrics / VictoriaLogs / Perses on
  `tharbad`, not Prometheus** (`llm-notes/done/observability-stack-migration.md`).
  Cluster metrics integration uses vmagent scraping, not
  kube-prometheus-stack. Dashboards stay in Perses (YAML-in-git).
- **liberl exposes storage via NFSv4 only today** (`hosts/liberl/nas.nix`).
  There is **no** iSCSI target, LIO/targetcli/scstadmin, or democratic-csi
  anywhere in the repo — the CSI/iSCSI work is greenfield, and is **deferred
  out of bootstrap** (D) since nothing here needs it.
- **`edith` currently lives on calvard** (Incus `dev` profile, 16 GB,
  lab VLAN 21, `10.97.21.42`), not erebonia. Relevant to the
  dev-env plan, not this one.

## Static-baseline deliverables (this flake)

### A. k3s server (all-in-one) on erebonia bare-metal

- `services.k3s` on erebonia with `role = "server"`, version pinned in the
  flake. The agent (kubelet/containerd/CNI) is **included** (no
  `--disable-agent`), so this single node is both control plane and worker.
  One systemd unit (`k3s.service`) — no microvm, no separate agent, no
  bootstrap-ordering machinery to sequence.
- Datastore: kine + SQLite at `/var/lib/rancher/k3s/server` on erebonia.
  **Decide persistence** — btrfs subvolume vs impermanence — and the
  **backup** story for the SQLite file (scheduled snapshot/copy; this is the
  cluster's source of truth, see "Open decisions"). This is the recovery
  mechanism that replaces the report's "rebuild the apiserver microvm."
- **apiserver (:6443) network confinement via the host**, not a VM: bind it
  to erebonia's management interface and gate access with the host firewall
  - the router6 `cluster` zone (E). Reachable from erebonia-local and
    selected clients (optionally remote `kubectl` via langport's proxy).
- Host prerequisites on erebonia: gVisor `runsc` binary, `pkgs.kata-runtime`
  (deployd's module owned this before; with deployd already removed, k3s is
  the sole owner of the kata runtime and
  `/etc/kata-containers/configuration.toml`), and a containerd shim
  configuration registering `runsc` and `kata-qemu`.
  - `pkgs.openiscsi` is **deferred** — added when the iSCSI/CSI work lands
    (D), not at bootstrap.
- **HelmChart + auto-apply manifests** in
  `/var/lib/rancher/k3s/server/manifests/` (declared in the flake, applied
  at cluster startup, all chart versions + values pinned):
  - `cert-manager` + a step-ca `ClusterIssuer` (step-ca runs on `basel`)
  - `kyverno` with ClusterPolicies scoped to the CI builds namespace only
  - `flux` bootstrapped against the dynamic-manifest path
  - _(deferred — added with the first CSI-needing workload, see D:
    `external-snapshotter` then `democratic-csi`)_
- **Storage:** k3s's bundled `local-path-provisioner` is the default
  StorageClass at bootstrap. Sufficient for the kine datastore, platform
  components, and DevPod workspaces (Phase A). No CSI yet.
- **RuntimeClass YAMLs**: `runc`, `runsc` (gVisor), `kata-qemu`,
  `runc-kvm` in the manifests directory.

(There is no "section B / C" anymore — collapsing the split removed the
separate-agent config and the `sd_notify`/apiserver-wait systemd chain the
report's split required.)

### D. liberl iSCSI target + CSI backing — DEFERRED (not part of bootstrap)

**Not needed to bootstrap the cluster, and not needed for Phase A.** Use
local storage first; stand this up when the first workload that needs
**VolumeSnapshots** or **NAS-backed durability** lands — which, in the
recommended order, is the **dev-env migration** (edith/trista KubeVirt
DataVolumes; VolumeSnapshot maps onto `incus snapshot`), or game servers,
whichever comes first. `local-path-provisioner` can't do VolumeSnapshots,
which is the actual trigger to do this work.

This is the hardest greenfield piece — liberl has no block-storage export
today — so keeping it off the bootstrap critical path is deliberate. When
it lands (owned by the dev-env plan), the work is:

- New NixOS module on liberl for an iSCSI target (LIO/targetcli or
  scstadmin).
- Dedicated ZFS dataset hierarchy under the `data` pool for
  cluster-allocated volumes.
- Service user with `zfs allow create,destroy,snapshot,clone` on that
  hierarchy.
- SSH or HTTP management endpoint for democratic-csi to issue ZFS
  commands; credentials in sops.
- `external-snapshotter` then `democratic-csi` (`zfs-generic-iscsi`) as
  HelmCharts in the k3s server manifests directory
  (`/var/lib/rancher/k3s/server/manifests/`); `pkgs.openiscsi` on erebonia.
- liberl's iSCSI portal reachable from the cluster zone (router6 forward
  rule: cluster → liberl TCP/3260; management endpoint over SSH/22 or HTTP)
  — add these rules to the cluster zone (E) at that time, not now.
- Validate the **full** lifecycle (provision → bind → snapshot → restore →
  delete) against the real liberl before betting workloads on it.

### E. router6 `cluster` zone (on thebeyond)

Add a `cluster` zone to `hosts/thebeyond/router.nix` (`router6.zones`).
Derive all addresses from the network registry via `forHost` — do **not**
hardcode IPs (the report's example hardcoded an incorrect phantasma IP).
Egress allows (translated from the report's example to live host roles):

- → `phantasma` (network zone) UDP/TCP 53 — DNS
- → `creil`, `langport` (dmz) TCP 443
- → `tharbad` (management) for metrics push (VictoriaMetrics ingest)
- → `liberl` (management) TCP 3260 (iSCSI) + SSH/HTTP mgmt endpoint —
  **deferred**, add with the CSI work (D), not at bootstrap.
- input: public-facing cluster services arrive via langport's nginx →
  erebonia k3s ingress (NodePort range or Traefik), not directly.

### F. Network registry + secrets

- **No new registry entry** — k3s runs on erebonia, which is already
  registered (`erebonia = 31`, management). The apiserver is just a port on
  that host. (The collapsed split means there's no k3s-server microvm to
  name/register.)
- Secrets via sops-nix: step-ca trust material and any cluster secrets. A
  single-node server generates its own CA/tokens — no shared agent join
  token is needed (there's no separate agent).
  (democratic-csi credentials are deferred with the CSI work, D.)

## No deployd coexistence (already removed)

Earlier drafts carried a deployd↔k3s coexistence audit (containerd socket
paths, CNI conflist dirs, bridge names, the shared kata config, duplicate
nested-KVM modprobe, port conflicts). **All of that is moot** — deployd is
already decommissioned (see the prerequisite at the top). On the clean
erebonia:

- k3s' agent owns containerd, the CNI, and
  `/etc/kata-containers/configuration.toml` outright — no sharing.
- The nested-KVM modprobe (`options kvm_intel nested=1`) now has a single
  owner at `hosts/erebonia/default.nix:53` (deployd's module that also set
  it is gone). Keep the host-level one, or move it under the k3s config —
  one declaration either way.
- Ports 6443/10250/10256/8472 are free (nothing else on erebonia uses them).

## Phase 0 — resource inventory & rollback check (prerequisite) — COMPLETE (2026-06-05)

Captured on the live, deployd-free erebonia:

- **CPU:** 11th Gen i5-1135G7, 4 cores / 8 threads. Fine for single-node.
- **RAM:** 15 GiB total, **~11 GiB available** under current load (Incus
  `trista` VM + `saint-arkh` microvm + system; swap is 0). k3s control plane
  + system pods (cert-manager, Kyverno, Flux, Traefik, coredns,
  metrics-server, local-path) realistically run ~2–3 GiB, leaving headroom
  for bootstrap **and** Phase A (a DevPod workspace). **Flag for the
  downstream dev-env plan, not this one:** the migration runs Incus
  (`trista`) and k3s *concurrently* before the Incus sunset reclaims memory —
  watch RAM there; bootstrap + Phase A are comfortable.
- **Disk:** 466 GB LUKS `cryptroot`, **415 GB free** — ample for the
  `local-path` provisioner and the datastore subvolume.
- **Filesystem:** **btrfs + impermanence confirmed** (`profiles/disko/btrfs.nix`,
  `common.btrfs.* ` in `hosts/erebonia/default.nix`). Decision #2's persisted
  btrfs subvolume + local btrfs snapshots is implementable as specified.
- **Rollback:** 17+ NixOS system generations present
  (`/nix/var/nix/profiles/system-*-link`). Recovery from a broken Phase 1 is
  `nixos-rebuild switch --rollback` or boot the prior generation from the
  boot menu (erebonia has a known-good generation 16/prior).

## Phase 1 implementation log (branch `k3s-bootstrap-erebonia`)

Phase 1 is being landed in reviewable chunks. The operator's constraint:
**erebonia-local changes first, the router6 `cluster` zone (E) as a separate
reviewed change**, and the cluster must be testable from a workstation. That
test path works *without* the router6 change because bt8-gateway already grants
VLAN 20/21 full access to VLAN 11 (management, erebonia's zone) — see
`project_bt8gw_vlan_20_21_to_11_access` memory — so only erebonia's host
firewall needs to open `:6443`.

Chunk map:

- **1a** — k3s control plane (datastore, snapshots, firewall, access). DONE.
- **1b** — runtime-tier baseline: gVisor + kata-qemu + runc-kvm + RuntimeClasses.
- **1c** — kata on cloud-hypervisor (`kata-clh`), via a nixpkgs override.
- **2** — platform HelmCharts: cert-manager + step-ca `ClusterIssuer`, Kyverno
  (builds-namespace policies), Flux against a placeholder dynamic path. All
  erebonia-local (auto-apply manifests / `services.k3s.charts`).
- **3** — router6 `cluster` zone on thebeyond (deliverable E). Separate reviewed
  change touching the live router; egress (DNS/443/metrics), input via langport.
  External-TLS termination at langport (decision #5) lands with/after this.

### Chunk 1a — k3s control plane — DONE (eval-validated, not yet deployed)

`hosts/erebonia/k3s/default.nix` (imported from `hosts/erebonia/default.nix`):

- `services.k3s` `role = "server"` (agent included), pinned `pkgs.k3s_1_33`
  (nixpkgs default is `1_35`; pinned minor, bump deliberately).
- Data on a dedicated btrfs subvolume `/persist/k3s` (`tmpfiles` `v`, decision
  #2) — survives the `@root` rollback (lives on `@persist`), independently
  snapshottable. Reached via a **symlink** `/var/lib/rancher/k3s → /persist/k3s`
  (`tmpfiles` `L+`), **not** `--data-dir`. Why: the NixOS k3s module hardcodes
  the auto-apply dirs (`manifestDir`/`chartDir`/`imageDir`/containerd-template)
  to the default `/var/lib/rancher/k3s/...` with no dataDir option, so
  `--data-dir` moved where k3s *reads* but not where the module *writes* —
  RuntimeClass/HelmChart manifests landed in an ignored dir (caught on the 1b
  deploy: the runtime RuntimeClasses didn't appear). The symlink makes the
  module's writes and k3s' reads coincide while keeping data on the subvolume;
  `/var` is on rolled-back `@root`, so tmpfiles recreates the symlink each boot.
- `k3s-datastore-snapshot` oneshot + daily timer: read-only `btrfs subvolume
  snapshot` of the data-dir, keep newest 14, prune older. Crash-consistent for
  the kine SQLite/WAL. Off-host copy to liberl deferred (CI/CD plan).
- `--tls-san` for `erebonia` / `erebonia.internal` / mgmt IPv4 / ULA so
  `kubectl` works by name/IP from a lab/trusted workstation.
- Host firewall: `trustedInterfaces = [cni0 flannel.1]` (pod→host traffic) and
  `:6443` opened from **trusted (VLAN 20) + lab (VLAN 21) only** via
  `extraInputRules` (merges with the existing SSH-tightening rule in
  `microvm/default.nix`). Management is **not** opened — host-local kubectl uses
  loopback, and no other mgmt host needs the kube API; untrusted (VLAN 30, where
  most devices live) is excluded. apiserver is the cluster root-of-trust, so its
  reach is scoped to the operator's kubectl-source zones. Network reach still
  requires a client cert/token to authenticate.
- `--write-kubeconfig-mode=0640`; `kubectl` + `KUBECONFIG` on the host.

**Deploy-test risks (operator validates — config is eval-clean only):** k3s
flannel/kube-proxy (iptables-nft) coexisting with incus's nftables + the
microvm macvtap networking on one host is the main integration unknown; verify
pod networking and that existing incus/microvm guests stay reachable after the
rebuild. Rollback is a prior generation.

### Chunk 1b — runtime-tier baseline (gVisor + kata-qemu + runc-kvm) — DONE

The cleanly-packaged runtimes and their RuntimeClasses, registered against the
**containerd 2.0** that k3s 1.33 bundles. Deferred from 1a deliberately:
containerd 2.0's runtime-config format differs from 1.x, so registration is
verified against the bundled containerd rather than hand-guessed.

Scope:

- **gVisor (`runsc`)** — `pkgs.gvisor` (ships `runsc` +
  `containerd-shim-runsc-v1`); RuntimeClass `runsc`. The sandbox boundary for
  untrusted build code.
- **kata-qemu** — `pkgs.kata-runtime` as packaged (it builds `HYPERVISORS=qemu`
  and ships `configuration-qemu.toml` + `containerd-shim-kata-qemu-v2`);
  RuntimeClass `kata-qemu`. The VM-isolation baseline; needs `/dev/kvm` +
  nested KVM (already enabled on erebonia).
- **runc-kvm** — runc handler with `/dev/kvm` exposed, for the AI-coding-layer
  nested-virt path; RuntimeClass `runc-kvm`.
- **RuntimeClasses** `runc` / `runsc` / `kata-qemu` / `runc-kvm` as manifests.

Open item to settle while building: whether k3s 1.33 auto-detects these and
generates the containerd handlers + RuntimeClasses, or whether we register them
explicitly via `containerdConfigTemplate` / manifests. Verify against the
bundled containerd; prefer explicit + pinned if auto-detect is partial.

**DONE (validated on erebonia 2026-06-05):** `kubectl get runtimeclass` shows
`runsc`/`kata-qemu`/`runc-kvm` (after the data-dir symlink fix — see 1a);
a `runsc` pod is sandboxed (`Starting gVisor...`); a `kata-qemu` pod runs as a
VM (runtime handler works).

**Correction to the original Phase-1 validation:** that line expected the
`kata-qemu` pod to reach `/dev/kvm` and boot a nested VM. **The stock nixpkgs
kata guest kernel cannot do this** — it is built `# CONFIG_VIRTUALIZATION is not
set`, so there is no `/dev/kvm` inside a kata pod (confirmed: `ls /dev/kvm` →
absent). Nested virt in kata needs a **custom guest kernel** (VIRTUALIZATION +
KVM + KVM_INTEL), and **kata-clh has the same limitation** (same
`vmlinux.container`). The host side is fine (nested KVM on, `-cpu host` exposes
vmx). This is an AI-coding-layer architecture decision, **not** a bootstrap
blocker — see the note under Phase 1 validation and
`project_kata_guest_kernel_no_nested_kvm`.

### Chunk 1c — kata on Cloud Hypervisor (`kata-clh`) — AFTER 1b

Swap the Kata VMM from QEMU to **cloud-hypervisor**. Split out from 1b because
it depends on 1b's *validated* containerd/RuntimeClass plumbing **and** a
separate nixpkgs package override — different work, different risk.

**Why this is easier under k3s than it was for deployd (operator question,
researched 2026-06-05):** k3s uses standard containerd, so kata-clh is the
mainstream path — register a `kata-clh` runtime handler
(`io.containerd.kata-clh.v2`, `ConfigPath` → clh toml) + a `kata-clh`
RuntimeClass. The shim symlink `containerd-shim-kata-clh-v2` already exists in
nixpkgs. deployd was a bespoke runtime, so the same goal meant hand-integrating
the shim into a non-standard stack; that friction is gone.

**The fix is small — verified by inspecting the built package** (not just the
build flags). Despite building `HYPERVISORS=qemu`, `kata-runtime` 3.29.0 **ships
`configuration-clh.toml`**, and it is **fully Nix-pathed**: `kernel` →
kata-images `vmlinux.container` (present), `image` → `kata-containers.img`
(present), `virtio_fs_daemon` → nixpkgs virtiofsd (present). The **only** broken
reference is the hypervisor binary: `path = "${kata-runtime}/bin/cloud-hypervisor"`
(+ `valid_hypervisor_paths`), but the package ships no `cloud-hypervisor` in
`$out/bin`. So the work is:

1. `kata-runtime.overrideAttrs` with a `postInstall` symlinking
   `${pkgs.cloud-hypervisor}/bin/cloud-hypervisor` → `$out/bin/cloud-hypervisor`.
   That's the whole packaging fix — no `HYPERVISORS=` rebuild, no toml editing;
   the shipped `configuration-clh.toml` then resolves as-is.
2. Register a `kata-clh` containerd runtime handler (drop-in, like 1b) with
   `ConfigPath` → `$out/share/defaults/kata-containers/configuration-clh.toml`.
3. Add a `kata-clh` RuntimeClass manifest.
4. Validate: a `kata-clh` pod boots under cloud-hypervisor and reaches
   `/dev/kvm`; nested test VM boots. CLH boots leaner/faster than QEMU — the
   reason to prefer it for the AI-coding-layer ephemeral sessions.

**Residual risk:** clh **version compat** — kata 3.29 targets a specific Cloud
Hypervisor; nixpkgs ships v52.0. If incompatible, pin a matching clh. This is
why 1b validates `kata-qemu` before 1c swaps the VMM. Needs `/dev/kvm` + nested
KVM (already on erebonia). See `project_nixpkgs_kata_qemu_only_clh_override`
memory.

## Phase 1 — land the cluster

Apply with `nixos-rebuild switch` on erebonia. (No liberl change — CSI is
deferred.) Validation:

- `systemctl status k3s.service` active (the single server unit — no
  microvm, no apiserver-wait oneshot).
- `kubectl get nodes` → erebonia Ready (single node, control-plane+worker).
- `kubectl get pods -A` → k3s system pods + cert-manager, Kyverno, Flux all
  Running. (No external-snapshotter/democratic-csi — deferred.)
- `kubectl get runtimeclass` → runc, runsc, kata-qemu, runc-kvm present.
- runsc test pod is sandboxed (gVisor kernel string ✅); kata-qemu test pod
  runs as a KVM VM (runtime handler works ✅).
  - **Nested virt is NOT achievable with stock kata** (corrected): the nixpkgs
    kata guest kernel is built `# CONFIG_VIRTUALIZATION is not set`, so there is
    no `/dev/kvm` inside a kata pod, and clh has the same limitation. The
    "boot a VM inside the sandbox" path the AI coding layer wants needs either a
    **custom kata guest kernel** (VIRTUALIZATION+KVM) or the **runc-kvm**
    host-`/dev/kvm`-passthrough tier (single-level). This is an AI-coding-layer
    (workloads Phase A) architecture decision, not a bootstrap gate. See
    `project_kata_guest_kernel_no_nested_kvm`.
- **local-path** PVC provisions, binds, and a pod mounts it (the storage
  path Phase A uses). VolumeSnapshot testing is deferred to the CSI work.
- cert-manager issues a Certificate from step-ca.
- Network policy behaves: pod↔pod ok, pod→host default-deny,
  pod→internet only via router6 allows.
- Appendix-A hostile test runs cleanly under runsc.

**Done when** the cluster comes up cleanly from a fresh rebuild, all
validations pass, and Flux reconciles a (placeholder) dynamic-manifest
path.

## Deferred — multi-node & HA (report Phases 10–11)

Capacity-driven, not maturity-driven; may be deferred indefinitely.
Recorded here because the control-plane topology is owned by this plan.

- **Phase 10 (multi-node):** single-node erebonia is sufficient at homelab
  scale. If expansion is wanted, **add a new dedicated worker host** rather
  than pulling calvard in — adding calvard inverts the failure-domain story
  (the static fleet would be exposed to cluster scheduling). The v17
  "add erebonia as worker to a calvard control plane" framing is obsolete:
  erebonia is already the cluster host.
- **Phase 11 (real HA):** add control-plane nodes on **other hosts** to
  reach a 3-voter etcd quorum — e.g. **liberl** as a voter tainted against
  workload scheduling (~1 GB/1 vCPU control-plane-only; etcd state on
  liberl's btrfs SSD root). More relevant than Phase 10 because it adds
  control-plane redundancy without inverting static-fleet isolation.
  - Note: a _dedicated HA control-plane node on another host_ may run as a
    small microvm or bare-metal — that's orthogonal to (and not a
    reinstatement of) the rejected erebonia apiserver-in-microvm split. The
    split we declined was wrapping the single node's own apiserver; adding
    real voter nodes on other hosts is a different thing.
- **kine → embedded-etcd migration** at HA expansion has no
  `k3s migrate-datastore`: snapshot SQLite, install fresh k3s with
  `--cluster-init` + embedded etcd, restore via etcd snapshot import,
  re-join nodes. Rehearse once on a throwaway cluster first; budget a
  brief outage.

Phases 10 and 11 are most valuable done together. See report Appendix C.

## Open decisions (need operator input)

1. **kube apiserver OIDC target. — RESOLVED.** Authelia is now the live IdP
   (Keycloak removed; `llm-notes/done/authelia-migration-plan.md`). The
   `kubectl` access path:
   OIDC via `kubectl oidc-login`, static kubeconfig on a trusted host, or
   both? (Report flags Authelia↔kube-apiserver OIDC compatibility as a
   risk — validate `kubectl oidc-login` in Phase 1; fall back to
   oauth2-proxy-shaped adapter or static bearer token if it mismatches.)
   **The rich IdP (lldap + Authelia) stays foundational — see
   `llm-notes/shelved/foundational-identity-resilience-plan.md`, which rejects
   moving it into the cluster. So `kubectl` OIDC here points at the foundational
   Authelia (tier-2 → tier-1, no circular dependency), and the on-disk x509
   admin kubeconfig is the cluster's own break-glass. That plan also adds an
   IdP-independent SSH-cert path so operator access to tier-1 hosts survives an
   Authelia outage.**
2. **kine datastore persistence + backup (on erebonia). — RESOLVED.**
   Dedicated **persisted btrfs subvolume** for `/var/lib/rancher/k3s/server`
   with **scheduled local btrfs snapshots** at bootstrap. **Off-host backup to
   liberl is deferred** — explored alongside the CI/CD plan (where closure/state
   durability is already in scope), not blocking bootstrap. Accepted risk: a
   disk loss on erebonia before the off-host story lands loses the datastore;
   acceptable for a greenfield single-node cluster whose platform is fully
   re-derivable from the flake.
3. **PKI overlap. — RESOLVED.** Standalone k3s control-plane CA, kept as a
   second trust root and **documented** as such. step-ca is bridged only for
   *workload* certs via the cert-manager `ClusterIssuer`; we do not make k3s'
   CA a step-ca intermediate (avoids fighting k3s' built-in cert rotation).
4. **Dynamic-manifest repo layout.** Monorepo path
   (`cluster/manifests/{infrastructure,apps}/`) vs separate repo. Not
   load-bearing for Phase 1; decide before the workloads plan.
5. **External-facing TLS. — RESOLVED.** Terminate Let's Encrypt at **langport's
   nginx** (existing pattern), proxying to erebonia's k3s ingress. No in-cluster
   ACME / separate public-TLS path.

## Rollback

Every step is a NixOS generation. `nixos-rebuild switch --rollback` or
boot the prior generation. deployd was already removed in its own prior
commit; if the dynamic-runtime were ever wanted back, revert that commit —
but since cc-sandbox is unused, no rollback to deployd is expected.
