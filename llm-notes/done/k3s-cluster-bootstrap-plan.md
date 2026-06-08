# k3s Cluster Bootstrap Plan

Status: **COMPLETE (shipped 2026-06-05).** The single-node bare-metal k3s
cluster is bootstrapped and deploy-validated on erebonia. All five open
decisions are resolved.

**Shipped:** chunks 1a (control plane: k3s server, persisted btrfs datastore
subvolume + daily snapshots, host-firewall :6443 scoping), 1b (runtime tiers
runsc / kata-qemu / runc-kvm + RuntimeClasses), 1c (kata-clh via the
cloud-hypervisor override, deploy-validated — pod boots under cloud-hypervisor;
`restartTriggers` makes runtime-registration changes apply on rebuild), and 2a/
2b/2c (cert-manager + step-ca ClusterIssuer Ready, Kyverno with builds-scoped
ClusterPolicies, Flux controllers healthy). **Chunk 3 dropped** — the cluster
masquerades behind erebonia's mgmt IP and erebonia is bt8gw-side, so **no
router6 or bt8gw firewall change is needed** (deliverable E).

**Deviations from the original plan (shipped as deferred, by design):**

- **OIDC kubectl access (decision #1) was NOT wired at bootstrap.** The apiserver
  has no `--oidc-*` flags; the **on-disk x509 admin kubeconfig is the bootstrap
  access path** (decision #1 resolved the _target_ as foundational Authelia, but
  break-glass x509 works today, so OIDC wiring + the `kubectl oidc-login`
  compat-validation are deferred until non-break-glass operator access is
  actually wanted). Not a blocker for Phase A.
- **Nested virt inside kata is not achievable** with the stock guest kernel
  (`# CONFIG_VIRTUALIZATION is not set`); kata-clh's win is leaner/faster boots,
  not in-pod KVM. A custom kata guest kernel (or the runc-kvm host-passthrough
  tier) is owned by the AI-coding-layer workload, not bootstrap.

**Deferred out of bootstrap to downstream plans (forward path, never in this
plan's scope to ship):** Flux `GitRepository`/`Kustomization` source (decision #4
resolved → **monorepo path** `cluster/manifests/{infrastructure,apps}/`; source
created in the workloads plan); liberl iSCSI + democratic-csi + external-
snapshotter (D — dev-env plan, triggered by the first VolumeSnapshot need);
public ingress langport→erebonia + the bt8gw `transit→management` rule, and
per-cluster egress confinement (E — first public / first untrusted workload);
off-host datastore backup to liberl (CI/CD plan); multi-node / HA (Phases 10–11,
capacity-driven). **Next work:** `llm-notes/plans/k3s-cluster-workloads-plan.md`
**Phase A** — the DevPod AI-coding layer (the cluster shakedown on local
storage).

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
2. `llm-notes/plans/incus-workstation-migration-plan.md` (edith + trista → KubeVirt,
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
  does **not** import router6. _(An early draft added a `cluster` zone here;
  that was dropped — erebonia is bt8gw-side and the cluster masquerades behind
  its mgmt IP, so thebeyond can't see it as a distinct zone. See deliverable E.)_
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
- **apiserver (:6443) network confinement via the host firewall**, not a VM and
  not a router zone: bind it to erebonia's management interface and gate access
  with erebonia's **host firewall** (Chunk 1a opens :6443 from trusted/VLAN 20 +
  lab/VLAN 21 only). bt8gw already routes those zones to management (VLAN 11),
  so kubectl from a workstation works with no router change; see deliverable E
  (a router6 `cluster` zone is **not** used — it isn't implementable here).
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
- liberl's iSCSI portal (TCP/3260) + SSH/HTTP mgmt endpoint: **no firewall
  rule needed** — liberl is in `management`/VLAN 11, the same subnet as erebonia,
  so iSCSI and the ZFS-mgmt endpoint are intra-VLAN L2 (same as basel/tharbad).
  The masqueraded cluster reaches them on erebonia's mgmt identity. (Confirm
  liberl's own host firewall admits the cluster/erebonia source on :3260 + the
  mgmt port when the CSI work lands — that's a liberl-host change, not a
  router/gateway one. See deliverable E.)
- Validate the **full** lifecycle (provision → bind → snapshot → restore →
  delete) against the real liberl before betting workloads on it.

### E. Cluster network reachability — NO router6 zone, NO new firewall rules (re-scoped)

The report (and earlier drafts of this plan) wanted a `cluster` zone on
thebeyond's router6 with per-target egress allows. **Dropped — it rests on a
false premise.** Two facts independently kill it:

1. **The cluster has no network identity off-host.** k3s/flannel masquerades
   (SNAT) all pod egress to erebonia's management IP (`10.97.11.31`) before it
   leaves the host. Anywhere downstream — bt8gw or thebeyond — "cluster traffic"
   is indistinguishable from "erebonia host traffic." There is no pod-CIDR to
   build a zone around.
2. **erebonia is bt8gw-side; thebeyond never sees it as a distinct zone.**
   erebonia lives in `management`/VLAN 11, whose `gateway = "bt8gw"`. To
   thebeyond, everything from bt8gw-side hosts arrives over the transit /30 and
   is classified as the single `transit` zone (`hosts/thebeyond/router.nix:364`;
   the comment is explicit — _"BT8-gateway's fw4 is the source-zone enforcer"_).
   thebeyond cannot match a `cluster` zone against traffic it only ever sees as
   `transit`.

So the cluster inherits erebonia's existing reachability. Each flow the report
wanted, mapped to the path it actually takes and what already permits it:

| Flow                          | Target zone             | Path                                         | Already permitted by                                                            |
| ----------------------------- | ----------------------- | -------------------------------------------- | ------------------------------------------------------------------------------- |
| basel:443 (cert-manager ACME) | management/11           | **intra-VLAN-11** (same subnet as erebonia)  | L2 — no forward chain. Proven: Chunk 2a issuer reached Ready.                   |
| tharbad (metrics/logs push)   | management/11           | **intra-VLAN-11**                            | L2 — no forward chain. erebonia already in the fluent-bit push set.             |
| liberl:3260 (iSCSI, deferred) | management/11           | **intra-VLAN-11**                            | L2 — no forward chain (when CSI lands).                                         |
| creil:443/80/22 (registry)    | app/50                  | bt8gw `management → app`                     | **Existing** `Allow-management-to-creil-forgejo` (src `10.97.11.0/24`).         |
| phantasma:53 (DNS)            | network/10 (thebeyond)  | bt8gw `management → transit` → thebeyond     | **Existing** management→transit (erebonia resolves DNS today).                  |
| internet (chart/image pulls)  | external                | bt8gw `management → transit` → thebeyond WAN | **Existing & proven** — Chunk 2 pulled quay.io/ghcr.io images.                  |
| kubectl :6443 ingress         | from trusted/20, lab/21 | bt8gw trusted/lab → management               | **Existing** (VLAN 20/21 → 11 access; `project_bt8gw_vlan_20_21_to_11_access`). |

**bt8gw firewall rules required for the cluster: NONE.** Every flow maps to a
`config forwarding` zone-pair directive that already exists on bt8gw
(`management → app`, `management → transit`, `trusted/lab → management`) or is
intra-VLAN-11 (no forward chain at all). On this fw4 version the zone-pair
directive is what actually permits traffic; per-flow `config rule` entries are
documentation/audit anchors only (see `BT8-gw-section-a-additions.uci` header).
The masqueraded cluster rides erebonia's host identity — and erebonia-the-host
already has all these flows. Chunk 2's successful deploy (public image pulls +
basel ACME registration) is the live proof.

- _Optional audit anchor (not required):_ if the operator wants the cluster's
  intended flows documented in bt8gw's fw4 in the established style, the only
  non-redundant anchor is erebonia → creil — and even that is already covered
  by the subnet-scoped `Allow-management-to-creil-forgejo` rule. So there is
  genuinely nothing to add.

**thebeyond firewall rules required: NONE at bootstrap.** The only future
thebeyond/transit touch is **public ingress**: when a public-facing cluster
service lands, langport's nginx (dmz/100, thebeyond-side) proxies to erebonia's
k3s ingress; that path crosses thebeyond `dmz → transit` **and** bt8gw
`transit → management` (which does not exist today and would be added then).
Deferred to the first public workload — decision #5 already terminates external
TLS at langport. No bootstrap workload is public (DevPod/Phase A is local;
dev-env is internal).

**Egress confinement — re-homed, optional, post-bootstrap.** The one legitimate
security goal buried in the original deliverable E — stop a compromised
CI/AI-coding pod from reaching the whole network/internet — **cannot** be
enforced on thebeyond (it can't see the cluster as distinct) and is only weakly
enforceable on bt8gw (it sees the cluster as erebonia-the-host, so tightening
there would also constrain the host). Real per-cluster egress confinement must
live **where pod traffic is still identifiable**:

- erebonia-local: host nftables on the flannel / pod-CIDR path, or an
  egress-enforcing CNI (Calico/Cilium — flannel can't), or
- a dedicated source identity for the cluster on bt8gw (don't masquerade the pod
  CIDR; route it and give it its own fw4 zone) — heavier, still bt8gw-side.

This matches the plan's deviation-from-report stance: put the security budget
into per-workload runtime tiers (kata/gVisor, landed in 1b), not network
gymnastics. Picked up if/when untrusted CI workloads actually land — not at
bootstrap.

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
  - system pods (cert-manager, Kyverno, Flux, Traefik, coredns,
    metrics-server, local-path) realistically run ~2–3 GiB, leaving headroom
    for bootstrap **and** Phase A (a DevPod workspace). **Flag for the
    downstream dev-env plan, not this one:** the migration runs Incus
    (`trista`) and k3s _concurrently_ before the Incus sunset reclaims memory —
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
**erebonia-local changes first**, with any router/gateway change as a separate
reviewed step, and the cluster must be testable from a workstation. That test
path works with **no** router or gateway change at all: bt8-gateway already
grants VLAN 20/21 full access to VLAN 11 (management, erebonia's zone) — see
`project_bt8gw_vlan_20_21_to_11_access` memory — so only erebonia's host
firewall needs to open `:6443`. The originally-planned router6 `cluster` zone
(Chunk 3) was subsequently **dropped** once it became clear the cluster
masquerades behind erebonia's bt8gw-side management IP and thebeyond therefore
can't see it as a distinct zone — see deliverable E. **Phase 1 is entirely
erebonia-local.**

Chunk map:

- **1a** — k3s control plane (datastore, snapshots, firewall, access). DONE.
- **1b** — runtime-tier baseline: gVisor + kata-qemu + runc-kvm + RuntimeClasses.
- **1c** — kata on cloud-hypervisor (`kata-clh`), via a nixpkgs override.
  DONE (eval-validated; awaiting operator deploy).
- **2** — platform HelmCharts: cert-manager + step-ca `ClusterIssuer`, Kyverno
  (builds-namespace policies), Flux against a placeholder dynamic path. All
  erebonia-local (auto-apply manifests / `services.k3s.autoDeployCharts`).
  DONE (deployed & validated); split into **2a** (cert-manager), **2b**
  (Kyverno), **2c** (Flux).
- **3** — ~~router6 `cluster` zone on thebeyond~~ **DROPPED** (deliverable E,
  re-scoped). The cluster masquerades behind erebonia's management IP and
  erebonia is bt8gw-side, so thebeyond never sees a distinct cluster zone and
  bt8gw already forwards every flow the cluster needs (management→app,
  management→transit, trusted/lab→management; intra-VLAN-11 for basel/tharbad/
  liberl). **No router6 or bt8gw firewall change at bootstrap.** Public ingress
  (langport→erebonia) and any egress-confinement hardening are deferred to the
  first untrusted/public workload — see deliverable E.

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
  `--data-dir` moved where k3s _reads_ but not where the module _writes_ —
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

### Chunk 1c — kata on Cloud Hypervisor (`kata-clh`) — DONE (eval-validated)

Swap the Kata VMM from QEMU to **cloud-hypervisor**. Split out from 1b because
it depends on 1b's _validated_ containerd/RuntimeClass plumbing **and** a
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

**Implementation log (eval-validated 2026-06-05, branch
`k3s-bootstrap-erebonia`):** landed in `hosts/erebonia/k3s/runtimes.nix`
alongside the 1b runtimes (all runtime-tier registration in one file). The
researched approach held exactly:

- The override (`kata-runtime.overrideAttrs` appending a `postInstall` symlink
  of `${pkgs.cloud-hypervisor}/bin/cloud-hypervisor` → `$out/bin/`) builds
  clean. Verified against the live nixpkgs pin: kata `3.29.0`, clh `52.0`,
  `containerd-shim-kata-clh-v2` already shipped, `configuration-clh.toml`
  shipped, no `cloud-hypervisor` binary in the stock package — all as the plan
  predicted.
- **The clh toml's `path` / `valid_hypervisor_paths` are self-referential to
  the derivation's own `$out`** (confirmed by reading the built toml), so the
  override's _new_ out is exactly where the toml looks — the shipped toml
  resolves as-is with zero editing. Built and checked: the toml's `path` now
  resolves through the symlink to the real `cloud-hypervisor-52.0` binary;
  `kernel`/`image`/`virtio_fs_daemon` (kata-images, virtiofsd) were already
  valid and are unchanged.
- The rendered containerd drop-in registers `kata-clh`
  (`io.containerd.kata-clh.v2`) with `ConfigPath` → the **override's** clh toml
  (distinct store path from the plain-runtime kata-qemu `ConfigPath` — verified
  in the rendered `10-extra-runtimes.toml`). The shim is found from the
  existing `pkgs.kata-runtime` on the k3s `PATH` (the kata shim binary is
  unchanged by the override, so qemu/clh shims are interchangeable; only
  `ConfigPath` selects the hypervisor). A `kata-clh` RuntimeClass manifest was
  added next to `runsc`/`kata-qemu`/`runc-kvm`.
- `nixosConfigurations.erebonia` toplevel evaluates clean; `kubectl get
runtimeclass` will show `kata-clh` after deploy.

**Operator deploy-validation (config is eval-clean only):**

- `nixos-rebuild switch` on erebonia; `kubectl get runtimeclass` → `kata-clh`
  present alongside the 1b classes.
- A `kata-clh`-class pod boots under cloud-hypervisor (check the kata logs /
  `ps` for `cloud-hypervisor`, not `qemu`). If it fails to boot, the prime
  suspect is the clh **version-compat** risk above — confirm by reading the
  shim/clh error and, if needed, pin a kata-matched clh.
- **Nested virt INSIDE the kata-clh pod is still NOT expected** — same stock
  guest-kernel limitation as kata-qemu (`# CONFIG_VIRTUALIZATION is not set`,
  no `/dev/kvm` in-pod). clh shares `vmlinux.container`. The reason to prefer
  clh is leaner/faster ephemeral boots, not nested KVM. See
  `project_kata_guest_kernel_no_nested_kvm`.

### Chunk 2 — platform HelmCharts — DONE (deployed & validated 2026-06-05)

**Validated on erebonia:** all three `HelmChart` installs Completed; pods Running
in `cert-manager`/`kyverno`/`flux-system`; the `step-ca` ClusterIssuer reached
`Ready=True` (ACME account registered against basel); Kyverno's two policies
deny a non-runsc/non-creil pod in `woodpecker-builds` under
`--dry-run=server` while admitting the same pod in `default` (scoping holds);
Flux controllers healthy with no source (deferred to #4, as designed).

All three components use the NixOS k3s module's `services.k3s.autoDeployCharts`
(fetches the chart `.tgz` at build time as a hash-pinned FOD, hands it to k3s'
helm-controller as a `HelmChart` CR — no in-cluster chart fetch, no imperative
`helm install`) plus `services.k3s.manifests.<name>.content` for the plain CRs.
Strictly **erebonia-local**: no basel/router change. Each chart's version + SRI
hash is pinned in-flake; bump deliberately. Chart FODs and rendered manifests
build clean; full deploy is the operator's to validate.

Files (imported from `hosts/erebonia/k3s/default.nix`):

#### Chunk 2a — cert-manager + step-ca `ClusterIssuer` (`k3s/cert-manager.nix`)

- `cert-manager` chart `v1.20.2` (jetstack), `crds.enabled = true`, single
  replica per component (homelab). Namespace `cert-manager` (created).
- A **`step-ca` `ClusterIssuer`** issued as a _separate_ auto-apply manifest
  (not the chart's `extraDeploy`), so k3s' deploy controller re-applies it until
  cert-manager's CRDs + webhook are serving, then it sticks — avoids the
  same-release admit-before-webhook race.
- **ACME against basel's existing `acme` provisioner** (`https://basel.internal.
mutantmell.net/acme/acme/directory`). Chosen over step-issuer/JWK precisely
  because it needs **no new provisioner on basel** — keeps Chunk 2 erebonia-local.
  Honors open decision #3: k3s keeps its own control-plane CA; step-ca is bridged
  in only for _workload_ certs via this issuer (two trust roots, documented).
- cert-manager pods don't inherit the host trust store (`common.internal-pki`
  seeds only the host), so the issuer carries `caBundle = base64(root ‖
intermediate)` from `data.pki` inline.
- **What validates now vs. later:** the issuer reaches **Ready** once
  cert-manager registers an ACME account against basel — and basel is in
  VLAN 11, the **same subnet** as erebonia, so that's intra-VLAN L2 with no
  firewall involved (validated in Chunk 2a). Issuing an actual `Certificate`
  also needs the declared **HTTP-01 solver** (Traefik ingressClass) reachable
  by step-ca, which depends on cluster **ingress** (langport → erebonia). With
  Chunk 3 dropped, that end-to-end check moves to the **first public/ingress
  workload**, not a router zone. So the bootstrap milestone is _issuer Ready_.
- **basel:443 needs NO firewall rule (correction to an earlier flag).** An
  earlier draft flagged a `cluster → basel TCP 443` egress allow for Chunk 3.
  That was wrong: basel is in `management`/VLAN 11, the **same subnet** as
  erebonia, so cert-manager→basel (SNAT'd to erebonia's mgmt IP) is pure
  intra-VLAN L2 — no router, no gateway, no forward chain. This very validation
  (issuer reached Ready via ACME against basel, with no router change) is the
  proof. There is no "cluster zone identifying pod-CIDR traffic" anywhere — the
  pod CIDR is masqueraded away on-host. See deliverable E.

#### Chunk 2b — Kyverno + `woodpecker-builds` ClusterPolicies (`k3s/kyverno.nix`)

- `kyverno` chart `3.8.1` (appVersion 1.18.1). **Lean install** — only the
  admission controller (1 replica); background/reports/cleanup controllers
  disabled (policy-report generation, mutate-existing, CleanupPolicy — none
  needed by admission-time Enforce). Namespace `kyverno` (created).
- Two `ClusterPolicy`s, **scoped to the `woodpecker-builds` namespace only**
  (the report's load-bearing warning: cluster-wide image/runtimeClass
  enforcement would deadlock bootstrap — kube-system/flux-system/cert-manager/
  kyverno would all be rejected). They're inert until that namespace exists:
  - `require-runsc-in-builds` — Pods must set `runtimeClassName: runsc`.
  - `restrict-image-registry-in-builds` — all containers (+ optional init/
    ephemeral) images must start with `creil.internal/`. **Confirm this prefix
    matches Woodpecker's actual registry push target** when CI lands (creil's
    Forgejo registry answers to both `creil.internal` and `forgejo.internal`).
  - Rule-level `validate.failureAction: Enforce`, `background: false` (the
    background controller is off). PSS-covered checks (hostPath/hostNet/
    privileged/root) are left to the namespace's PSS `restricted` labels.
- **Not created here** (belong to the CI workload — workloads-plan Phase 4 /
  report Appendix A): the `woodpecker-builds` namespace itself, its PSS labels,
  the NetworkPolicy, and the Woodpecker server/runners. Bootstrap ships only the
  engine + the scoped policies.

#### Chunk 2c — Flux controllers (`k3s/flux.nix`)

- `flux2` chart `2.18.4` (CNCF Flux upstream, community chart; appVersion
  2.8.8). Namespace `flux-system` (created). Image-automation + image-reflector
  controllers disabled (registry tag-watching, unused); helm/kustomize/source/
  notification kept.
- **Controllers only.** The `GitRepository` + `Kustomization` pointing Flux at
  the dynamic-manifest path are deliberately **not** created here. Decision #4 is
  now **resolved — monorepo path** (`cluster/manifests/{infrastructure,apps}/` in
  this repo), but the concrete source (repo URL + read auth, branch/tag) is an
  implementation detail still owned by the workloads plan and sequenced after the
  DevPod shakedown — so the bootstrap milestone stays "controllers Running/
  healthy; source created in the workloads plan." (Refines the "Flux reconciles a
  placeholder path" done-criterion below.)

**Deploy-test risks (operator validates — config is eval-clean only):** chart
images pull from public registries (quay.io/ghcr.io) on first start — needs
erebonia outbound; cert-manager webhook readiness gates the ClusterIssuer's
first successful apply (expect a few retries in the deploy controller log before
it goes Ready); the ACME account registration needs erebonia→basel:443. RAM:
the three platforms + their webhooks land within the Phase-0 ~2–3 GiB control-
plane budget, but watch the admission/webhook pods on the 11 GiB node.

## Phase 1 — land the cluster

Apply with `nixos-rebuild switch` on erebonia. (No liberl change — CSI is
deferred.) Validation:

- `systemctl status k3s.service` active (the single server unit — no
  microvm, no apiserver-wait oneshot).
- `kubectl get nodes` → erebonia Ready (single node, control-plane+worker).
- `kubectl get pods -A` → k3s system pods + cert-manager, Kyverno, Flux all
  Running. (No external-snapshotter/democratic-csi — deferred.)
- `kubectl get runtimeclass` → runc, runsc, kata-qemu, kata-clh, runc-kvm present.
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
- cert-manager: the `step-ca` ClusterIssuer reaches **Ready** (ACME account
  registered against basel — intra-VLAN-11, no firewall change). Issuing an
  actual Certificate end-to-end needs the HTTP-01 solver reachable (cluster
  ingress, langport → erebonia), so that check moves to the **first
  public/ingress workload** (Chunk 3 dropped — see deliverable E and the
  Chunk 2a log).
- Pod networking behaves: pod↔pod ok, pod→host default-deny (host firewall
  `trustedInterfaces = [cni0 flannel.1]` from Chunk 1a). Pod egress is
  **masqueraded to erebonia's mgmt IP** and rides erebonia's existing
  reachability (DNS/internet/registry) — no router6 allow is involved and none
  is added (deliverable E). Per-cluster egress _confinement_, if wanted later,
  is erebonia-local (CNI/nftables), not a router change.
- Appendix-A hostile test runs cleanly under runsc.

**Done when** the cluster comes up cleanly from a fresh rebuild, all
validations pass, and the Flux controllers are Running/healthy. (Flux
reconciling an actual dynamic-manifest path is gated on open decision #4 — the
`GitRepository`/`Kustomization` source is deferred to the workloads plan; see
the Chunk 2c log.)

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
   _workload_ certs via the cert-manager `ClusterIssuer`; we do not make k3s'
   CA a step-ca intermediate (avoids fighting k3s' built-in cert rotation).
4. **Dynamic-manifest repo layout. — RESOLVED.** **Monorepo path** (not a
   separate repo): the cluster's dynamic manifests live in _this_ dotfiles repo
   under a structured path — `cluster/manifests/{infrastructure,apps}/` — and
   Flux reconciles that subtree. Rationale: one source of truth alongside the
   Nix platform definition; no second repo to provision, mirror, or auth
   separately. **Still to nail in the workloads plan** (implementation detail,
   not a decision): the `GitRepository` URL Flux points at + its read auth
   (deploy key / token for this repo's forge), and whether Flux watches a branch
   or tag. Creating the `GitRepository`/`Kustomization` source remains deferred
   to the workloads plan (see the Chunk 2c log) — it's no longer _blocked on a
   decision_, just sequenced after the DevPod shakedown.
5. **External-facing TLS. — RESOLVED.** Terminate Let's Encrypt at **langport's
   nginx** (existing pattern), proxying to erebonia's k3s ingress. No in-cluster
   ACME / separate public-TLS path.

## Rollback

Every step is a NixOS generation. `nixos-rebuild switch --rollback` or
boot the prior generation. deployd was already removed in its own prior
commit; if the dynamic-runtime were ever wanted back, revert that commit —
but since cc-sandbox is unused, no rollback to deployd is expected.
