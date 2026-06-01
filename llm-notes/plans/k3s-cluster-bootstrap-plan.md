# k3s Cluster Bootstrap Plan

Status: Planned (not started)

Source report: `llm-notes/reports/k8s-migration-evaluation.md` (v20).
This plan implements **Phase 0–1** of that report, plus the deferred
multi-node / HA topology (Phases 10–11) as a forward-looking section.

Depends on: nothing in-repo (greenfield). Optional dependency on
`llm-notes/plans/authelia-migration-plan.md` if OIDC `kubectl` access is
wanted at bootstrap (see "Open decisions").

Foundation for (in recommended execution order — **migrate existing
workloads onto the cluster before adding net-new features**):
1. `llm-notes/plans/k3s-deployd-migration-plan.md` (cc-sandbox + deployd sunset)
2. `llm-notes/plans/k3s-dev-env-migration-plan.md` (edith KubeVirt, Incus sunset)
3. `llm-notes/plans/k3s-cluster-workloads-plan.md` (blog, game servers, CI — last)

The migrations (1, 2) are what prove the cluster; the new features (3) come
after the existing stuff is moved over. This reorders the report's phase
numbering (the report ran new workloads as Phases 2–4 *before* the
cc-sandbox/edith migrations) per operator priority.

Reverses the k3s rejection in `llm-notes/specs/dynamic-container-layer.md`
(see that spec's line ~47 alternatives table). deployd itself is already
shelved in favour of this direction — see
`llm-notes/shelved/deployd-integration.md`.

---

## Goal

Stand up a single-node k3s cluster on **erebonia** with a *split control
plane*:

- **`k3s server`** (apiserver, controller-manager, scheduler, kine+SQLite)
  inside a **microvm guest on erebonia** — `--disable-agent`, no kubelet.
- **`k3s agent`** (kubelet, kube-proxy, containerd, CNI, all pods) on
  **erebonia bare-metal** — native hardware access for kata-qemu,
  `/dev/kvm`, NUMA, native networking.

Everything platform-level is declared in this flake; a fresh
`nixos-rebuild switch` on erebonia must bring the whole platform up with
no manual `helm install` or imperative steps. Rollback is
`nixos-rebuild switch --rollback` / boot the prior generation.

The split confines the API surface to a controlled-network microvm — the
same pattern already used for deployd-api (`roer`) and the OIDC provider
(`messeldam`) — while letting workloads run with bare-metal performance.

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
  The report says "Authelia"; an Authelia migration is *planned*
  (`llm-notes/plans/authelia-migration-plan.md`) but not done. kube
  apiserver OIDC should target whichever provider is live when Phase 1
  lands. See "Open decisions".
- **Observability is VictoriaMetrics / VictoriaLogs / Perses on
  `tharbad`, not Prometheus** (`llm-notes/done/observability-stack-migration.md`).
  Cluster metrics integration uses vmagent scraping, not
  kube-prometheus-stack. Dashboards stay in Perses (YAML-in-git).
- **liberl exposes storage via NFSv4 only today** (`hosts/liberl/nas.nix`).
  There is **no** iSCSI target, LIO/targetcli/scstadmin, or democratic-csi
  anywhere in the repo — the CSI/iSCSI work below is greenfield.
- **`edith` currently lives on calvard** (Incus `dev` profile, 16 GB,
  lab VLAN 21, `10.97.21.42`), not erebonia. Relevant to the
  dev-env plan, not this one.

## Static-baseline deliverables (this flake)

### A. k3s server microvm on erebonia

- New microvm guest under `hosts/erebonia/microvm/guests/<name>/`
  (Trails-themed name; pick + register in network registry). Built via
  `lib.mk-microvm` (the same builder `roer`/`saint-arkh` use). ~2 GB RAM,
  2 vCPU initially. cloud-hypervisor backend to match the fleet (the
  report flags cloud-hypervisor balloon support as a risk — fall back to
  QEMU as a one-off if balloon misbehaves).
- `services.k3s` in the guest with `role = "server"`,
  `extraFlags = "--disable-agent"`. Version pinned in the flake.
- Datastore: kine + SQLite on the guest filesystem. **Decide persistence**
  — btrfs subvolume vs impermanence, and the backup story for the SQLite
  file itself (Velero protects cluster state, not the datastore under it).
  See "Open decisions".
- One virtio-net interface on a controlled-exposure bridge; apiserver
  reachable only from erebonia and (optionally) selected tailnet clients
  via langport's proxy if remote kubectl is wanted.
- **HelmChart + auto-apply manifests** in
  `/var/lib/rancher/k3s/server/manifests/` (declared in the flake, applied
  at cluster startup, all chart versions + values pinned):
  - `external-snapshotter` (VolumeSnapshot CRDs — must apply before
    democratic-csi)
  - `cert-manager` + a step-ca `ClusterIssuer` (step-ca runs on `basel`)
  - `democratic-csi` (`zfs-generic-iscsi` driver targeting liberl)
  - `kyverno` with ClusterPolicies scoped to the CI builds namespace only
  - `flux` bootstrapped against the dynamic-manifest path
- **RuntimeClass YAMLs**: `runc`, `runsc` (gVisor), `kata-qemu`,
  `runc-kvm` in the manifests directory.

### B. k3s agent on erebonia bare-metal

- `services.k3s` on erebonia with `role = "agent"`,
  `serverAddr = "https://<server-microvm>:6443"`, `tokenFile` → a
  sops-managed shared token.
- Host prerequisites on erebonia: gVisor `runsc` binary,
  `pkgs.kata-runtime` (already present via deployd's module — coordinate
  version pinning, see coexistence below), `pkgs.openiscsi`, and a
  containerd shim configuration registering `runsc` and `kata-qemu`.

### C. Bootstrap ordering (systemd)

Per the report — host-side oneshot waits for the apiserver, agent waits
for the oneshot:

```nix
systemd.services.k3s-apiserver-wait = {
  wants  = [ "microvm@<server-microvm>.service" ];
  after  = [ "microvm@<server-microvm>.service" "network-online.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${pkgs.curl}/bin/curl --retry 60 --retry-delay 2 \
      --retry-connrefused --cacert <ca> https://<server-microvm>:6443/readyz";
  };
};
systemd.services.k3s = {              # the agent
  wants = [ "k3s-apiserver-wait.service" ];
  after = [ "k3s-apiserver-wait.service" ];
};
```

microvm.nix's `sd_notify`-over-vsock integration means
`microvm@<name>.service` only completes when the guest signals ready; the
oneshot then confirms the apiserver responds; the agent waits for both.

### D. liberl iSCSI target + CSI backing (parallel work, greenfield)

This is the hardest greenfield piece — liberl has no block-storage export
today.

- New NixOS module on liberl for an iSCSI target (LIO/targetcli or
  scstadmin).
- Dedicated ZFS dataset hierarchy under the `data` pool for
  cluster-allocated volumes.
- Service user with `zfs allow create,destroy,snapshot,clone` on that
  hierarchy.
- SSH or HTTP management endpoint for democratic-csi to issue ZFS
  commands; credentials in sops.
- liberl's iSCSI portal reachable from the cluster zone (router6 forward
  rule: cluster → liberl TCP/3260; management endpoint over SSH/22 or HTTP).

Validate the **full** lifecycle (provision → bind → snapshot → restore →
delete) against the real liberl in Phase 1, before any workload depends on
it (game servers, dev-env DataVolumes).

### E. router6 `cluster` zone (on thebeyond)

Add a `cluster` zone to `hosts/thebeyond/router.nix` (`router6.zones`).
Derive all addresses from the network registry via `forHost` — do **not**
hardcode IPs (the report's example hardcoded an incorrect phantasma IP).
Egress allows (translated from the report's example to live host roles):

- → `phantasma` (network zone) UDP/TCP 53 — DNS
- → `creil`, `langport` (dmz) TCP 443
- → `tharbad` (management) for metrics push (VictoriaMetrics ingest)
- → `liberl` (management) TCP 3260 (iSCSI) + SSH/HTTP mgmt endpoint
- input: public-facing cluster services arrive via langport's nginx →
  erebonia k3s ingress (NodePort range or Traefik), not directly.

### F. Network registry + secrets

- Register the k3s-server microvm in `lib/common/data/network.nix`
  (`name = hostId; # comment`) in an appropriate zone (management mirrors
  `roer`'s pattern for an API surface).
- Shared k3s token, democratic-csi credentials, and step-ca trust material
  via sops-nix.

## Coexistence with deployd during transition

Phases 1–6 have deployd and k3s both live on erebonia. Audit (Phase 0)
and keep them non-conflicting:

- containerd socket paths: k3s under `/run/k3s/containerd/`; deployd uses
  the system containerd — distinct.
- CNI conflist dirs: `/var/lib/rancher/k3s/agent/etc/cni/net.d/` (k3s) vs
  `/etc/cni/net.d/` (deployd) — distinct.
- bridge names: `cni0` (flannel) vs `deploy-dmz` (deployd) — distinct.
- **kata config is the real footgun**: both want
  `/etc/kata-containers/configuration.toml`. Pin `pkgs.kata-runtime` to a
  single version across both during the transition; this collapses when
  deployd is removed (see `k3s-deployd-migration-plan.md`, Phase 6).
- **nested-KVM modprobe is declared twice today**: deployd's module sets
  `options kvm_intel nested=1` and `hosts/erebonia/default.nix:53` sets it
  again at host level. Resolve the duplicate (pick one owner).
- Ports free on erebonia: 6443, 10250, 10256, 8472.

## Phase 0 — inventory & coexistence audit (prerequisite)

- Capture erebonia resources (`free -h`, `nproc`, `lscpu`, disk). Project
  the workload sum: deployd + `roer` (512 MB/2 vCPU) + `saint-arkh`
  (4 GB/4 vCPU if deployed) + `trista` (Incus) + k3s overhead (4–8 GB) +
  cluster workloads. Confirm headroom.
- Walk the coexistence table above against live erebonia.
- Verify NixOS rollback: known-good prior generation in the boot menu;
  document the "Phase 1 broke erebonia" recovery procedure.

## Phase 1 — land the cluster

Apply with `nixos-rebuild switch` on erebonia (and liberl for the CSI
target). Validation (from the report):

- `systemctl status microvm@<server>.service` active;
  `k3s-apiserver-wait.service` succeeded; `k3s.service` (agent) active.
- `kubectl get nodes` → erebonia Ready.
- `kubectl get pods -A` → k3s system pods + cert-manager,
  external-snapshotter, democratic-csi, Kyverno, Flux all Running.
- `kubectl get runtimeclass` → runc, runsc, kata-qemu, runc-kvm present.
- runsc test pod is sandboxed (gVisor kernel string); kata-qemu test pod
  runs in a KVM VM and can reach `/dev/kvm` (the cc-sandbox case).
- democratic-csi PVC provisions on liberl, binds, snapshots via
  VolumeSnapshot.
- cert-manager issues a Certificate from step-ca.
- Network policy behaves: pod↔pod ok, pod→host default-deny,
  pod→internet only via router6 allows.
- deployd coexistence intact: a deployd container still runs; `roer`'s
  deployd-api still serves.
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
- **Phase 11 (real HA):** add **liberl** as a third control-plane voter,
  tainted against workload scheduling (~1 GB/1 vCPU control-plane-only
  microvm; etcd state on liberl's btrfs SSD root). More relevant than
  Phase 10 because it adds control-plane redundancy without inverting
  static-fleet isolation.
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
2. **Cluster microvm persistent state + datastore backup.** btrfs subvol
   vs impermanence for `/var/lib/rancher/k3s/server`; backup story for the
   kine SQLite file separate from Velero.
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
boot the prior generation. deployd stays fully declared until the
deployd-migration plan retires it, so the prior dynamic-runtime path
remains available throughout.
