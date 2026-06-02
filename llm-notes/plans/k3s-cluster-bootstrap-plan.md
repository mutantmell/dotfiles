# k3s Cluster Bootstrap Plan

Status: Planned (not started)

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20).
This plan implements **Phase 0–1** of that report, plus the deferred
multi-node / HA topology (Phases 10–11) as a forward-looking section.

Depends on: nothing in-repo (greenfield). Optional dependency on
`llm-notes/plans/authelia-migration-plan.md` if OIDC `kubectl` access is
wanted at bootstrap (see "Open decisions").

**Prerequisite (do this first): remove deployd.** Since cc-sandbox is
unused, deployd has no workload — decommission it **before** standing up
k3s (see `llm-notes/plans/k3s-deployd-migration-plan.md`). Doing this first
means k3s lands on a clean erebonia with **no deployd coexistence to
manage** (no shared kata config, no duplicate nested-KVM modprobe, no
containerd/CNI/bridge/port audit). This is the single biggest simplification
to the bootstrap.

Foundation for (recommended execution order, after deployd removal +
bootstrap):

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

Rationale: remove deployd first (no workload), then bootstrap on a clean
host. The AI coding layer (dev containers) is built first as a low-stakes
shakedown on local storage that proves the cluster before the daily-driver
edith moves. This reorders the report's phase numbering (it ran net-new
workloads as Phases 2–4 before the migrations).

Reverses the earlier k3s rejection that motivated deployd (the
dynamic-container-layer spec, since deleted — see the report
`llm-notes/reports/k8s-migration-evaluation.md` for the reversal). deployd
is being retired in favour of this direction — see
`llm-notes/plans/k3s-deployd-migration-plan.md`.

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
  (deployd's module owned this before; with deployd removed first, k3s is
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

## No deployd coexistence (removed first)

Earlier drafts carried a deployd↔k3s coexistence audit (containerd socket
paths, CNI conflist dirs, bridge names, the shared kata config, duplicate
nested-KVM modprobe, port conflicts). **All of that goes away** because
deployd is decommissioned before k3s lands (see the prerequisite at the
top). On a clean erebonia:

- k3s' agent owns containerd, the CNI, and
  `/etc/kata-containers/configuration.toml` outright — no sharing.
- Settle the single owner of the nested-KVM modprobe (`options kvm_intel
nested=1`) — deployd's module set it and `hosts/erebonia/default.nix:53`
  also sets it; after deployd removal, keep just the host-level one (or
  move it under the k3s config). One declaration, not two.
- Ports 6443/10250/10256/8472 are free (nothing else on erebonia uses them).

## Phase 0 — resource inventory & rollback check (prerequisite)

- Capture erebonia resources (`free -h`, `nproc`, `lscpu`, disk). Project
  the workload sum on the now-deployd-free host: `saint-arkh` + `trista`
  (until it migrates) + k3s overhead (4–8 GB) + cluster workloads. Confirm
  headroom. (deployd/`roer` are gone, freeing their footprint.)
- Verify NixOS rollback: known-good prior generation in the boot menu;
  document the "Phase 1 broke erebonia" recovery procedure.

## Phase 1 — land the cluster

Apply with `nixos-rebuild switch` on erebonia. (No liberl change — CSI is
deferred.) Validation:

- `systemctl status k3s.service` active (the single server unit — no
  microvm, no apiserver-wait oneshot).
- `kubectl get nodes` → erebonia Ready (single node, control-plane+worker).
- `kubectl get pods -A` → k3s system pods + cert-manager, Kyverno, Flux all
  Running. (No external-snapshotter/democratic-csi — deferred.)
- `kubectl get runtimeclass` → runc, runsc, kata-qemu, runc-kvm present.
- runsc test pod is sandboxed (gVisor kernel string); kata-qemu test pod
  runs in a KVM VM and can reach `/dev/kvm`, and a nested NixOS test VM
  boots inside it (the nested-virt path the AI coding layer needs — the
  thing deployd couldn't do).
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

1. **kube apiserver OIDC target.** Keycloak now, Authelia later
   (`authelia-migration-plan.md`)? And the operator `kubectl` access path:
   OIDC via `kubectl oidc-login`, static kubeconfig on a trusted host, or
   both? (Report flags Authelia↔kube-apiserver OIDC compatibility as a
   risk — validate `kubectl oidc-login` in Phase 1; fall back to
   oauth2-proxy-shaped adapter or static bearer token if it mismatches.)
2. **kine datastore persistence + backup (on erebonia).** btrfs subvol vs
   impermanence for `/var/lib/rancher/k3s/server`; scheduled backup of the
   kine SQLite file (separate from Velero, which protects cluster _state_,
   not the datastore underneath). This is now the primary control-plane
   recovery mechanism (it replaces the rejected microvm-rebuild path), so
   it matters more than before — settle it at bootstrap.
3. **PKI overlap.** k3s' internal control-plane CA as a second trust root
   alongside step-ca (acceptable, just document), or make k3s' CA a
   step-ca-signed intermediate?
4. **Dynamic-manifest repo layout.** Monorepo path
   (`cluster/manifests/{infrastructure,apps}/`) vs separate repo. Not
   load-bearing for Phase 1; decide before the workloads plan.
5. **External-facing TLS.** Terminate Let's Encrypt at langport's nginx
   (existing pattern, simpler) vs in-cluster Traefik + separate ACME.

## Rollback

Every step is a NixOS generation. `nixos-rebuild switch --rollback` or
boot the prior generation. deployd is removed in the prerequisite step
(its own commit) — if for any reason the dynamic-runtime is wanted back
before k3s is ready, revert that commit; but since cc-sandbox is unused,
no rollback to deployd is expected.
