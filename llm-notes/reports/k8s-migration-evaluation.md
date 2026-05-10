# Kubernetes Migration Evaluation

Date: 2026-05-09 (v19 — see revision history at end)

## Question

Should we replace the dynamic-container layer (`deployd`,
single-host on erebonia) with a Kubernetes-based runtime? If yes,
what shape should the deployment take? Could it replace any static
microvm guests or the Incus dev-environment hosts?

## Recommendation

**Stand up a Kubernetes cluster (k3s) on erebonia with a split
control plane: `k3s server` (apiserver, controller-manager,
scheduler, kine) runs inside a microvm guest; `k3s agent`
(kubelet, kube-proxy, containerd, CNI) runs on erebonia
bare-metal. Build new dynamic workloads on it. Migrate
cc-sandbox into the cluster early — its current deployd
nested-virt story is broken; bare-metal kata-qemu or runc-kvm
fixes it. Migrate edith into the cluster once it has matured.
Leave the static microvm.nix fleet on calvard untouched. Sunset
deployd once the cluster has proven itself. NixOS rollback is
the recovery mechanism — every change is boot-time reversible.**

The split gives bare-metal performance and direct hardware
access for workloads (kata-qemu, `/dev/kvm`, NUMA, etc.) while
keeping the Kubernetes API surface contained inside a microvm
whose network exposure is controlled — same pattern the homelab
applies to other API surfaces (deployd-api in roer, Authelia in
messeldam, etc.). The bootstrap dependency from agent →
apiserver is handled cleanly via microvm.nix's systemd
socket-notification integration.

The endgame is a simpler control-plane layout than today:

| Today | Endgame |
| --- | --- |
| NixOS + microvm.nix + Incus + deployd + (planned k8s) | NixOS + microvm.nix + k8s |
| 4 active control planes | 3 |

The migration is phased and reversible at every step — NixOS + git is
the rollback story. Each phase can be reverted by reverting the
relevant commits, and the previous tools (Incus, deployd) remain
declared in the flake until the new pattern has run reliably.

### What goes where

| Workload | Home today | Home endgame | Notes |
| --- | --- | --- | --- |
| k3s control plane (apiserver, kine, etc.) | — | erebonia microvm | API surface confined to a microvm, same pattern as other homelab API surfaces |
| k3s agent (kubelet, containerd, CNI, pods) | — | erebonia bare-metal | Workloads run with native hardware access — kata, /dev/kvm, NUMA, etc. |
| Blog (planned) | — | k8s | First cluster workload; canonical Deployment + Flux pattern |
| Game servers (planned) | — | k8s | CSI VolumeSnapshot replaces the custom iSCSI add-on |
| CI runners (saint-arkh deferred) | — | k8s | Woodpecker kubernetes backend + per-step gVisor-sandboxed pods |
| Claude sandboxes | deployd (broken nested-virt) | k8s with kata-qemu (or runc-kvm) | Migrate early — bare-metal access fixes the nested-virt problem deployd has; runtime per Appendix A |
| edith dev environment | Incus (calvard) | k8s Pod (erebonia) | StatefulSet + PVC; cross-host but liberl-backed CSI handles it |
| trista | Incus (erebonia) | resolved per Phase 6 | Role ambiguous (inventory says dev env; code says dmz-vm; registry says bastion); leave alone for now |
| Authelia and other small foundational services | microvm.nix (calvard) | microvm.nix (calvard) | Per-service failure domain wins; calvard not pulled into cluster |
| Static fleet (Forgejo, Jellyfin, Prometheus, etc.) | microvm.nix (calvard) | microvm.nix (calvard) | Don't migrate what works |

### Why this answer

The full chain of reasoning that produced it (across revisions of
this report):

- **The earlier rejection of k3s** in
  `llm-notes/specs/dynamic-container-layer.md:47` was anchored
  on a bare-metal mental model where k3s' bundled defaults
  (Traefik, ServiceLB, flannel) would conflict with router6
  and declared NixOS choices. **Inside a microvm**, those
  components live in the cluster's network namespace and
  don't touch host-level infrastructure — the conflict goes
  away. With Caddy on host being a deployd-specific concern
  rather than a homelab-wide pattern, k3s' bundled stack is
  actually well-suited: most components are kept (CoreDNS,
  metrics-server, kine, flannel, Traefik), few are touched.
- **kubelet + containerd is a better-supported sandbox-runtime
  integration path** than nerdctl + containerd. Most of the
  deployd friction lives in the nerdctl glue layer, not in
  containerd; under k8s, gVisor (the chosen sandbox tier for
  untrusted code) plugs in via the same containerd-shim
  mechanism without the nerdctl issues.
- **Operator ecosystem fit is real** for CI runners (autoscaling
  runner controllers like ARC) and game servers (CSI
  VolumeSnapshot vs. building a custom iSCSI add-on).
- **Split control plane on erebonia is the right shape.**
  Erebonia is already the dynamic-compute host (runs deployd
  today with kata as default runtime, has nested-KVM
  enabled). Putting the apiserver inside a microvm preserves
  the homelab's pattern of confining API surfaces to a
  controlled-network microvm guest (deployd-api in roer,
  Authelia in messeldam). Putting the agent on bare-metal
  preserves the workload-performance benefits that motivated
  v18's pivot: kata-qemu without nested-virt penalty, direct
  `/dev/kvm` for cc-sandbox, native CPU and network for game
  servers. Neither host imports router6
  (`hosts/erebonia/default.nix`); failure-domain isolation
  between the cluster and the static fleet is preserved by
  host choice — calvard hosts the static fleet, erebonia
  hosts the cluster.
- **Dev environments in k8s is a mature pattern** (Coder, Gitpod,
  Codespaces, DevPod) — the previous "k8s is for cattle, not pets"
  framing was outdated.
- **Consolidating dev environments and dynamic workloads in one
  cluster** pools resources between guests that breathe (edith
  idle vs. CI runner peak) and removes Incus as a separate
  control plane.
- **NixOS + git makes the migration reversible.** Every phase can
  be reverted; the previous tools stay declared until the new
  pattern is proven.

## LLM-assisted operations as a design driver

Several decisions in this report — and in the homelab broadly
— reflect a principle worth naming: **infrastructure should be
designed such that LLM-assisted operations is a first-class
concern.** Configurations and operational state should live as
LLM-readable text in version control, not as opaque runtime
state mediated by web UIs or imperative tools.

This isn't an aesthetic preference; it's a workflow choice
based on the operator routinely using LLM coding assistants
for debugging, configuration, and infrastructure decisions.

Where it already shows up in the homelab:

- NixOS as the primary substrate (declarative, text, semantic)
- `llm-notes/` with explicit lifecycle directories
  (`plans`, `wip`, `done`, `shelved`, `specs`, `guides`,
  `reports`) and CLAUDE.md at the repo root
- Consistent naming (Trails-themed, systematically applied)
- The network registry (`lib/common/data/network.nix`)
  consolidating cross-cutting state in one readable place
- **Perses over Grafana** for dashboards — YAML-in-git is
  LLM-readable; Grafana's JSON-in-DB-edited-via-web-UI is not.
  Perses isn't a bet on it succeeding as next-gen Grafana;
  it's fitness-for-purpose for this workflow.
- cc-sandbox itself — running Claude Code in isolated
  environments operationalizes the workflow

### Implications for the k8s direction

The principle reinforces several decisions made elsewhere in
this report:

- **GitOps via Flux** over imperative `kubectl apply`. Cluster
  state is reconcilable from git; "what's running and why" is
  answerable by reading manifests.
- **Platform components declared in NixOS** via k3s' bundled
  stack and HelmChart resources (with pinned versions and
  values in the flake) rather than ad-hoc `helm install`.
- **Workload manifests in git** rather than state living only
  in etcd. Flux applies them, but text is the source of truth.
- **Avoidance of tools whose state lives in mutable runtime
  stores** — Grafana dashboards in a DB, drifting helm
  releases, `kubectl edit` workflows.

### A failure-mode lesson worth retaining

The v11 → v12 revision of this report was itself a failure of
this principle in practice. v11 recommended kube-prometheus-
stack without checking `llm-notes/done/` first; the relevant
migration document (`observability-stack-migration.md`) had
already documented the move off Prometheus and Grafana. The
repo is designed so the relevant history is one directory read
away; the failure was not using the design as intended.

The lesson: when reasoning about adjacent infrastructure, the
`done/` directory is the first stop, not a fallback. This
applies to me writing the report and equally to any future
LLM-assisted work on the homelab.

## Platform vs. dynamic: where the boundary sits

The architectural principle that drives several decisions in this
report:

- **Platform**: capabilities the cluster needs to function as a
  platform. Always present, always coherent, declared in NixOS,
  reproduced on rebuild. Workloads assume these exist.
- **Dynamic**: workloads that use those capabilities. Come and go
  independently of platform changes. Operated through the
  cluster's own APIs (kubectl / Flux), not via NixOS rebuilds.

The boundary is **not** "installed via NixOS module" vs.
"installed via Helm." The mechanism doesn't matter — Helm
releases can be declared in NixOS and applied at cluster
bootstrap. The boundary is **what the thing is**: a baseline
capability vs. a workload.

### What lives where

**Static baseline (declared in this flake):**

- NixOS host configurations (calvard, erebonia, eventually
  liberl)
- microvm.nix guest declarations for the static fleet, plus
  the **k3s-server microvm** on erebonia
- **`services.k3s` in server mode inside the k3s-server
  microvm** (`role = "server"; extraFlags = "--disable-agent"`)
  — version pinned, datastore is kine+SQLite on the microvm's
  filesystem
- **k3s HelmChart resources** (manifests/ directory in the
  microvm) declaring cert-manager (with step-ca
  ClusterIssuer), external-snapshotter, democratic-csi,
  Kyverno, Flux — applied automatically at cluster startup,
  all chart versions and values pinned in the flake
- **RuntimeClass YAMLs** for runc / runsc / kata-qemu /
  runc-kvm in the microvm's manifests directory
- **`services.k3s` in agent mode on erebonia bare-metal**
  (`role = "agent"; serverAddr = "https://<microvm>:6443"`)
- **systemd dependency ordering** so agent waits for the
  microvm to be ready (microvm@k3s-server →
  k3s-apiserver-wait oneshot → k3s agent)
- **gVisor's `runsc` binary**, kata-runtime, containerd shim
  configuration in the agent's containerd template, and
  iSCSI client tools on erebonia — host-level prerequisites
  the agent relies on
- router6 zones (cluster zone with explicit egress allows)
- langport's nginx forwarding rules (for public-facing cluster
  services routed through the existing reverse proxy)
- Certificates and secrets at NixOS level (sops-nix)

**Dynamic layer (cluster manifests, watched by Flux, NOT in
NixOS modules):**

- Application Deployments / StatefulSets / Services
- Workload-specific NetworkPolicy, ConfigMap, Secret resources
- Image tags / digests for application versions
- The blog's content config, the game server's settings, the CI
  pipeline definitions

The dynamic layer can live in this same git repo (e.g.,
`cluster/manifests/`) or a separate one. Either way, it's
operationally separate from the NixOS layer — Flux watches it,
nothing in the flake references it directly.

### Why this rules out vanilla `services.kubernetes.*`

The vanilla NixOS k8s modules pitch at "declare your entire
cluster in the flake" — they pull cluster API resources up into
the static layer. That violates the principle: it forces the
dynamic layer's cadence (workload changes) into the static
layer's cadence (NixOS rebuilds).

k3s' module is shaped right: it declares the cluster as a unit,
including its bundled platform capabilities (CoreDNS, Traefik,
flannel, etc.), but doesn't try to express the workload layer
in NixOS terms. Workloads land via Flux from the dynamic-
manifest path, not via NixOS evaluation.

### Fresh-install reproducibility

The principle implies a specific test: **a completely fresh
install must produce a fully operational platform with no manual
steps.**

1. `nixos-rebuild switch` on the cluster's host
2. Cluster microvm provisions and boots
3. k3s starts with its bundled stack (CoreDNS, metrics-server,
   kine+SQLite, kube-proxy, kube-router, flannel, Traefik,
   ServiceLB, local-path-provisioner)
4. k3s' HelmChart controller and `manifests/` auto-apply
   pick up cert-manager, external-snapshotter, democratic-csi,
   Kyverno, Flux, and the RuntimeClass YAMLs (runc / runsc /
   runc-kvm)
5. Flux starts watching the workload manifest path
6. Cluster is fully operational, ready for workloads

No manual `helm install`. No "first do this, then do this"
runbook for the platform. Reproducibility falls out of NixOS'
normal model. Workloads are then deployed to the dynamic layer
on whatever cadence makes sense, independent of the platform.

## Architecture

### Cluster topology — split control plane

The cluster is split across two NixOS-managed surfaces on
erebonia:

- **`k3s server` microvm** (cluster control plane). Runs
  apiserver, controller-manager, scheduler, kine+SQLite
  datastore, HelmChart controller, and the auto-apply
  manifests directory. Configured with `--disable-agent` so
  no kubelet runs inside. Tiny footprint (~1–2 GB RAM, 2
  vCPU). API exposed only on the microvm's controlled
  network interface.
- **`k3s agent` on erebonia bare-metal**. Runs kubelet,
  kube-proxy, containerd, the CNI plugins (flannel + kube-
  router), and all the workload pods. Bare-metal hardware
  access — kata-qemu without nested KVM, direct `/dev/kvm`
  passthrough for cc-sandbox, native CPU/network for game
  servers.

The split mirrors the homelab's existing pattern of confining
API surfaces (deployd-api in roer, Authelia in messeldam) to
microvm guests with controlled network exposure, while
allowing workload execution to happen wherever it best fits.

Communication between agent and server is standard k3s mTLS
over a virtio-net interface — the kubelet on erebonia connects
to the apiserver in the microvm just as it would to a
different physical node. Both directions are mTLS-authenticated
via k3s-managed certs.

### Bootstrap ordering via systemd socket notification

The bootstrap concern (kubelet needs apiserver to be ready
before it starts) is resolved cleanly via microvm.nix's
systemd integration. microvm.nix uses `sd_notify` over vsock
so the host-side `microvm@<name>.service` unit waits until the
guest signals readiness. A small additional host-side oneshot
verifies the apiserver itself is responding (not just that
the microvm has booted), and the `k3s` agent service depends
on that oneshot:

```nix
# Host-side oneshot: wait for apiserver to respond
systemd.services.k3s-apiserver-wait = {
  description = "Wait for k3s apiserver in microvm";
  wants = [ "microvm@k3s-server.service" ];
  after = [ "microvm@k3s-server.service" "network-online.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${pkgs.curl}/bin/curl --retry 60 --retry-delay 2 \
      --retry-connrefused --cacert <ca> https://<microvm>:6443/readyz";
  };
};

# Agent depends on apiserver being ready
systemd.services.k3s = {
  wants = [ "k3s-apiserver-wait.service" ];
  after = [ "k3s-apiserver-wait.service" ];
};
```

Result: a clean `nixos-rebuild switch` brings the system up in
the right order without manual sequencing. If the microvm
hasn't started, the agent waits; if the apiserver isn't
responding, the agent waits. No race conditions, no manual
intervention.

### Runtime isolation tiers (unchanged from v18)

For workloads requiring stronger-than-runc isolation, the
cluster provides:

- **gVisor** (`runsc`) — userspace syscall sandbox. Used for
  CI step pods running untrusted build code. Software-enforced
  boundary; no hardware-virtualization cost.
- **kata-qemu** — full KVM VM per pod, hardware-enforced
  kernel isolation. With erebonia bare-metal there's no nested
  virtualization (the host has `/dev/kvm` natively;
  `kvm_intel nested=1` is already set per
  `hosts/erebonia/default.nix`). This is the canonical
  k8s-with-kata pattern used by AWS Fargate, GKE Sandbox, etc.
  Used for cc-sandbox where stronger isolation matters and
  where direct `/dev/kvm` access is needed for nested NixOS
  test VMs.
- **runc-kvm** — runc + `/dev/kvm` device passthrough.
  Fallback for cc-sandbox sessions if kata-qemu's guest kernel
  has nested-KVM limitations (the issue that originally drove
  cc-sandbox off kata in deployd).

The per-workload runtime mapping (gVisor for CI, kata for
cc-sandbox) is more nuanced than v15's "gVisor for everything
sandboxed" because bare-metal removes the nested-KVM penalty
that made kata expensive.

### Why erebonia, not calvard

Erebonia is the right host for the cluster, not just a
viable one:

- **Role-fit.** Erebonia is the homelab's dynamic-compute host
  today — runs deployd with kata as default, has nested-KVM
  enabled, hosts saint-arkh (planned CI runner microvm). Its
  role is "ephemeral compute lives here." k3s replacing
  deployd on the same host is consistent with that role.
- **Static-fleet isolation preserved by host choice.** Calvard
  hosts the static fleet — Authelia/Keycloak (messeldam),
  step-ca (basel), Forgejo (creil), nginx/oauth2-proxy
  (langport), Jellyfin (oracion), VictoriaMetrics/Loki/etc.
  (tharbad), edith (Incus container). None on erebonia. An
  erebonia kernel panic does not affect foundational identity,
  PKI, observability, or static-content services. The
  failure-domain boundary is the host boundary, not the
  hypervisor boundary.
- **Eliminates the nested-virt penalty.** kata-qemu in a
  microvm running on cloud-hypervisor would be three KVM
  levels (host → microvm → kata pod). Bare-metal kata is one
  level (host → kata pod). cc-sandbox's nested-NixOS-test-VM
  workflow gets direct access to the host's `/dev/kvm`. Game
  servers when they land get bare-metal CPU and network.
- **The cluster host wasn't fixing anything router6.**
  Verified: `hosts/erebonia/default.nix` does not import
  `modules/router6/`. The mechanical-isolation argument
  earlier revisions leaned on was overstated; router6 only
  runs on `thebeyond` (the actual router). erebonia's
  host-side networking is standard NixOS + microvm.nix bridges
  + Incus bridges + (future) k3s bridges. Coexistence is
  workable.
- **Recovery via NixOS rollback.** Every change is boot-time
  reversible (`nixos-rebuild switch --rollback` or boot a
  previous generation). If Phase 1 breaks erebonia, recovery
  is "boot previous generation, fix the broken commit." This
  is the safety net that earlier revisions tried to provide
  via microvm-confinement; NixOS already provides it.

### Costs of the split, named honestly

- **One more microvm to maintain.** ~1–2 GB RAM, 2 vCPU for
  the apiserver microvm. Small relative to the rest of the
  fleet; declares cleanly through `mk-microvm`.
- **Marginal apiserver↔kubelet latency.** virtio-net adds ~10–
  30µs per round trip. For homelab scale, imperceptible. The
  apiserver is chatty (heartbeats, watch streams) but it's
  all flowing through a local virtio interface, not a
  network.
- **Kubelet, containerd, and CNI still run on erebonia bare-
  metal.** A kubelet bug, runaway pod, or kernel panic in
  containerd still takes down the host's workload-execution
  surface. The split confines only the API surface, not the
  workload-execution surface. The mitigation is NixOS
  rollback for kubelet config and per-pod resource limits
  (Kyverno-enforced); existing pod state is cached by kubelet
  and survives apiserver downtime.
- **Cluster reset is split.** Apiserver reset is "destroy the
  microvm, rebuild" (clean). Agent reset is "clean up k3s
  state on erebonia" (heavier). Each operation is independent.

Net: this is meaningfully cleaner than v18's pure-bare-metal
recommendation. The microvm boundary for the API surface adds
real defense-in-depth without giving up the workload-side
performance benefits.

### Coexistence with deployd during transition

Phases 1–8 have k3s and deployd both running on erebonia. This
is a short window (months, not the year v17 envisioned —
Phase 8 cc-sandbox migration is accelerated). The audit checklist
below identifies coexistence touchpoints; **Phase 1
validation must confirm each item before workloads land.**

| Touchpoint | k3s side | deployd side | Conflict risk |
|---|---|---|---|
| containerd socket | `/run/k3s/containerd/containerd.sock` | `/run/containerd/containerd.sock` | None — different paths |
| Container runtime | k3s' embedded containerd | host containerd via `virtualisation.containerd.enable` | Two daemons; resource overhead small |
| CNI conflists | `/var/lib/rancher/k3s/agent/etc/cni/net.d/` | `/etc/cni/net.d/${cfg.bridge.name}.conflist` (deploy-dmz) | Different directories — verify k3s isn't reading `/etc/cni/net.d/` |
| Bridge interfaces | flannel `cni0`, pod CIDR `10.42.0.0/16` | `deploy-dmz`, `10.97.100.0/24` | No name or CIDR collision |
| kata-qemu config | `/etc/kata-containers/configuration.toml` | same file (set by deployd) | **Shared config file** — k3s' kata RuntimeClass reads the same one. Audit during Phase 1; consider pinning kata version. |
| Kernel modules | vhost, vhost_net, vhost_vsock, kvm | same | Loaded by both; additive |
| `boot.extraModprobeConfig` | n/a | sets `options kvm_intel nested=1` | Already set by erebonia's `hosts/erebonia/default.nix:51`; deployd's `modules/deployd/default.nix:521` redundant |
| Ports | 6443 (apiserver), 10250 (kubelet), 10256 (kube-proxy), 8472 (flannel VXLAN) | none on these | None |
| `/dev/kvm` access | shared (no exclusive lock) | shared | Both can use it; KVM is multi-tenant |

The **kata config sharing** is the only real footgun. Both
deployd's existing kata workloads and k3s' kata RuntimeClass
will read `/etc/kata-containers/configuration.toml`. Pinning
the kata-runtime nixpkgs version is the right hedge.

### Performance

The split control plane keeps workloads on bare-metal-erebonia
(no virtualization overhead for actual pod execution) while
the apiserver runs in a microvm (virtualization overhead on
the API control path, which is small and fixed). Per-runtime
cost on the workload side is the only execution overhead:

| Runtime | Overhead vs. bare-metal runc |
| --- | --- |
| runc (default) | 0% — native processes on the host kernel |
| runsc (gVisor) | ~10–30% on syscall-heavy workloads, ~equal on compute-bound |
| kata-qemu | ~10–20% CPU per pod (full KVM VM); near-equal network/storage with virtio-fs/virtio-net |
| runc-kvm | 0% for the runc layer; nested-KVM cost only for workloads that actually spawn nested VMs |

For the named workloads:

- **Blog**: invisible (runc on bare-metal).
- **CI runners under gVisor**: ~10–20% slower than native for
  syscall-heavy steps (dependency installs, file-heavy builds);
  near-native for compute-heavy steps. Same penalty as v15-v17
  estimated; bare-metal removed the v6-era virtio overhead on
  top of it.
- **cc-sandbox under kata-qemu**: ~10–20% CPU overhead per
  pod; storage/network near-native. Direct `/dev/kvm` for
  nested NixOS-test VMs without nested-virt penalty (this was
  the broken case under deployd's runc-kvm-in-microvm story).
- **cc-sandbox under runc-kvm fallback** (if kata-qemu's guest
  kernel has nested-KVM issues): near-bare-metal everything,
  weaker isolation than kata.
- **Game servers under runc**: native — direct CPU and
  network. Imperceptible to players.
- **edith dev environment under runc**: comparable to today
  (Incus container on calvard); cross-host access to PVCs
  hosted on liberl NAS adds NFS or iSCSI latency, similar to
  Incus's network-storage path.

**Control-plane path overhead:** kubelet on erebonia talks to
apiserver in the microvm over virtio-net. ~10–30µs per round
trip vs. localhost; the apiserver is chatty (heartbeats,
watch streams) but this is all running on the same physical
host with a virtual NIC, not over a network. Imperceptible at
homelab scale; mentioned for completeness.

**Workload-execution path overhead:** zero virtio penalty —
pods run directly on erebonia's kernel. This is the main
performance benefit vs. the v17 framing where workloads ran
inside the cluster microvm.

### Community pattern

Running k8s inside VMs on a hypervisor is the **dominant deployment
shape** for non-bare-metal k8s, not a niche choice:

- Managed cloud k8s (EKS/GKE/AKS) — every node is a VM on the
  cloud's hypervisor.
- Enterprise vSphere / Tanzu — k8s nodes are VMs on vSphere.
- Talos Linux — designed as a minimal OS for k8s, deployed almost
  exclusively as VMs on Proxmox/vSphere/cloud.
- Proxmox + Talos / k3s / k0s VMs — the recommended homelab
  pattern in r/homelab and the Proxmox forums. Proxmox docs
  explicitly discourage running k8s in LXC (shared-kernel issues
  mirror what kata had with mutable NixOS).
- Cluster API providers for Proxmox, vSphere, OpenStack assume
  this pattern.

Bare-metal k8s exists (Talos, Tinkerbell) but is the minority
shape. The unusual choice in this homelab would be running k8s on
bare metal alongside microvm.nix guests, not running k8s in a
microvm.

## Dual firewall: router6 stays authoritative

### How rules from multiple sources compose on Linux

Both `nft` and `iptables-nft` write to the same kernel `nf_tables`
backend. Multiple chains can attach to the same hook (input,
forward, output, prerouting, postrouting). Within a hook, chains run
in priority order, **and a packet must clear every chain to pass —
any chain dropping a packet drops it for everyone**.

Two firewalls don't act independently. They cooperate to produce
one combined verdict per packet. That foundation makes "additive
only" feasible: if router6's chain says drop, the CNI cannot
un-drop.

### The microvm framing simplifies this

With the cluster in a microvm:

- router6 lives in the host kernel's `nf_tables`. The cluster's
  CNI lives in the microvm kernel's `nf_tables`. Different
  kernels, different netfilter instances, no chain composition.
- router6 sees the cluster as one guest with one source IP at the
  microvm boundary.
- Pods masquerade to the microvm's IP at egress (Cilium
  `bpf.masquerade=true`); router6 enforces what that microvm IP
  is allowed to do.

Each firewall is reasoned about with its own kernel's tooling.
There's no priority ordering to worry about, no
`bridge-nf-call-iptables` interaction, no NAT-order ambiguity, no
reload races (a `nixos-rebuild` on the host doesn't touch the
microvm; a `kubectl apply` doesn't touch the host).

### The architecture

In router6:

```nix
router6.zones.cluster = {
  icmpEcho = "disable";
  accessTo = [ "internet" ];
  forwardRules = {
    dmz = [
      { proto = "tcp"; daddr = creil.ipv4;    dport = 443; }
      { proto = "tcp"; daddr = langport.ipv4; dport = 443; }
    ];
    management = [
      { proto = "tcp"; daddr = tharbad.ipv4;  dport = 9090; }
    ];
    network = [
      { proto = "udp"; daddr = phantasma.ipv4; dport = 53; }
      { proto = "tcp"; daddr = phantasma.ipv4; dport = 53; }
    ];
  };
  inputRules = [
    # langport's nginx fronts external traffic to the cluster's NodePort range
    { proto = "tcp"; saddr = langport.ipv4; dport = 30000-32767; }
  ];
};
```

Cluster-side: k3s' bundled flannel + kube-router NetworkPolicy
provides per-pod policy. flannel masquerades pod egress to the
erebonia's host IP by default, so router6 sees a single
source IP for all cluster-originated traffic. kube-router
enforces NetworkPolicy on pod-to-pod and pod-to-external
flows. No additional CNI configuration is required for this
posture.

NetworkPolicy resources further restrict which pods may talk to
which destinations. NetworkPolicy is structurally
**deny-after-allow**: it can only subtract from what the underlying
network already permits. **router6 is the ceiling**; the CNI cannot
grant connectivity that router6 denies.

### Trade-offs to accept up-front

- **Pods masquerade to the microvm's IP at egress.** router6 sees
  microvm-IP-as-source for all pod traffic; per-pod policy lives
  in NetworkPolicy.
- **`Type=LoadBalancer` (via MetalLB) and hostPort exposures
  are off-limits.** They assume host-side firewall control the
  cluster doesn't grant. Cluster services expose as
  `ClusterIP` + `NodePort`; HTTP routing is handled by k3s'
  bundled Traefik inside the cluster, with langport's existing
  nginx fronting public-facing services (or SNI passthrough to
  erebonia:443).
- **Drift risk.** An operator adds a NetworkPolicy that opens
  egress to something router6 hasn't been told about; developers
  see unexplained drops. Failure mode is fail-closed (good) but
  annoying. Mitigation: maintain a single doc that lists every
  "cluster needs to reach X" requirement and the corresponding
  rule in both layers.

## Platform components — all NixOS-declared

Each of these is declared in erebonia's NixOS configuration
and applied at cluster startup via k3s' bundled mechanisms
(HelmChart CRD, `manifests/` auto-apply directory).
None require manual post-install steps; a fresh
`nixos-rebuild switch` produces a fully operational platform.

- **Distribution: k3s** (`services.k3s` from nixpkgs — mature,
  maintained module). Bundles the canonical k3s stack: CoreDNS,
  metrics-server, kine+SQLite, kube-proxy, kube-router
  NetworkPolicy controller, flannel, Traefik, ServiceLB,
  local-path-provisioner. **On erebonia bare-metal**, this
  bundle coexists with deployd during the transition; see the
  coexistence audit in the Architecture section. The
  earlier rejection of k3s was anchored on a bare-metal mental
  model where flannel and Traefik would fight router6 and
  host Caddy; with the cluster confined to a microvm, those
  components live in the microvm's network namespace and don't
  touch the host. Vanilla `services.kubernetes.*` is rejected
  for a different reason — it violates the platform/dynamic
  boundary by pulling workload concerns into NixOS evaluation.
- **Hypervisor backend**: cloud-hypervisor (matches existing
  pattern). Validate balloon support in Phase 1; fall back to
  QEMU if needed. Discussed earlier under "Hypervisor backend."
- **Datastore: kine + SQLite** (k3s default). Single-node;
  trivial backup/restore (one file). Migration to embedded etcd
  at HA expansion (Phase 11) is documented but non-trivial:
  snapshot SQLite → install fresh k3s with `--cluster-init` and
  embedded etcd → restore → re-join nodes. Rehearse once before
  Phase 11; budget a brief outage. Not "off the critical path"
  — it's a real migration, just well-bounded.
- **CNI: flannel** (k3s bundled). VXLAN backend; manages
  iptables-via-`iptables-nft` inside the microvm. The kube-router
  NetworkPolicy controller (also k3s bundled) provides standard
  NetworkPolicy enforcement. Cilium with eBPF would give us
  Hubble flow observability and CiliumNetworkPolicy
  expressiveness; for the homelab's traffic volumes and use
  cases, flannel + kube-router is sufficient. If those features
  become genuinely needed, swap in via
  `--flannel-backend=none --disable-network-policy
  --disable-kube-proxy` + Cilium HelmChart.
- **Ingress: Traefik** (k3s bundled). Handles HTTP routing for
  cluster-hosted services. Requires cert-manager + step-ca
  ClusterIssuer for TLS — see below. Bundled Traefik replaces
  the previously-recommended host-Caddy proxy: with deployd
  sunset, host Caddy was deployd-specific and no longer needed.
  Public-facing cluster services route via langport's existing
  nginx (or via SNI passthrough → erebonia:443 → Traefik). Tailnet-only services route directly to cluster
  microvm:443.
- **TLS: cert-manager + step-ca ClusterIssuer**, declared as a
  HelmChart resource. Now load-bearing: Traefik consumes
  Certificate-issued Secrets, all cluster-internal TLS flows
  through this. The step-ca on basel issues short-TTL certs;
  cert-manager handles renewal automatically.
- **CSI: democratic-csi against liberl NAS**, declared as a
  HelmChart. Provides VolumeSnapshot for game servers and dev
  environments — alongside k3s' bundled local-path-provisioner,
  which stays as the default StorageClass for ephemeral / cache
  state (build caches, scratch volumes, etc.). Workloads pick
  via `storageClassName`. **NAS-side requirements are real
  engineering work**, not a checkbox: liberl needs a NixOS
  module for an iSCSI target (LIO/targetcli or scstadmin), an
  SSH or HTTP API endpoint for democratic-csi to issue
  `zfs create/snapshot/destroy` calls, a dedicated ZFS dataset
  hierarchy for cluster-allocated volumes, and a service user
  with appropriate `zfs allow` permissions. Pick the
  democratic-csi driver — `zfs-generic-iscsi` is the most
  flexible for a NixOS-based ZFS NAS; alternatives are
  `freenas-iscsi` (TrueNAS-specific, not us) and
  `zfs-generic-nfs` (simpler but no block-device snapshots).
  iSCSI client tools (`pkgs.openiscsi`) live in the cluster
  microvm itself; VolumeSnapshot CRDs ship via
  `external-snapshotter` HelmChart, **applied before**
  democratic-csi (CRD ordering matters).
- **Admission policy: Kyverno**, declared as a HelmChart. Base
  ClusterPolicies enforce that **the `woodpecker-builds`
  namespace** has image source = creil and `runtimeClassName:
  runsc` (the Appendix A policies). Critically, **scope these
  policies to the untrusted-code namespace, not cluster-wide** —
  applying image-source enforcement to `kube-system`,
  `flux-system`, `cert-manager`, `kyverno`, `cilium-*` etc.
  would deadlock the bootstrap. Per-workload policy refinements
  live in the dynamic layer.
- **GitOps: Flux v2**, declared as a HelmChart, configured to
  bootstrap against the dynamic-manifest path in this flake.
  Once running, Flux reconciles the dynamic layer.
- **RuntimeClasses**: declared as Kubernetes resources via k3s'
  `manifests/` auto-apply directory (single small YAML files,
  not Helm). Bare-metal-on-erebonia makes kata viable as a
  first-class option (no nested-KVM penalty), so the runtime
  set is broader than the v15 framing.
  - `runc` (default) — trusted code: foundational service
    workloads, the blog, game servers, edith dev environment
  - `runsc` (gVisor) — sandboxed untrusted code: CI step pods
    running build scripts and dependencies. Userspace
    syscall implementation; ~10–30% syscall-heavy overhead;
    no kernel-virt cost. Installed via the gVisor containerd
    shim configured in k3s' containerd template.
  - `kata-qemu` — hardware-isolated workloads: **cc-sandbox by
    default**. Full KVM VM per pod with QEMU as the VMM;
    ~10–20% CPU per pod. On bare-metal erebonia this is the
    canonical k8s-with-kata pattern (host KVM directly; no
    nesting). Critically, cc-sandbox pods get `/dev/kvm`
    inside the kata VM for nested NixOS-test VMs — the
    workflow that was broken under deployd's runc-kvm-in-
    microvm story.
  - `runc-kvm` — fallback for cc-sandbox if kata-qemu's guest
    kernel can't handle nested NixOS-test VMs (the recurrence
    of the kata-kernel-nested issue that originally drove
    cc-sandbox off kata). Validated during Phase 8; the
    decision between kata-qemu and runc-kvm for cc-sandbox is
    deferred until then.

### cc-sandbox isolation tier — bare-metal reopens kata

With erebonia bare-metal, cc-sandbox's isolation story is
substantially better than under deployd or under the v17
microvm-confined plan:

- **deployd today**: cc-sandbox runs as `runc` (host kernel
  shared with deployd-managed workloads). `/dev/kvm`
  passthrough works for some sessions but nested NixOS-test
  VMs hit kata-kernel-nested launcher hangs (the original
  reason cc-sandbox was moved to runc).
- **v17 microvm-confined plan**: cc-sandbox would run as
  `runsc` (gVisor) by default, downgrading to `runc-kvm`
  per-session for `/dev/kvm` needs. gVisor was the right
  isolation tier given nested-virt costs, but `runc-kvm`
  sessions still had a triple-KVM stack to deal with.
- **v18 bare-metal plan**: cc-sandbox runs as `kata-qemu` by
  default — hardware-enforced KVM isolation **plus** direct
  host `/dev/kvm` access for nested workloads inside the
  kata VM. No nested-virt penalty for the cluster; the
  nesting cost is paid only inside pods that actually use it.
  This is strictly stronger isolation than the v17 plan and
  strictly better performance for nested workloads than the
  deployd story.

The trade: `kata-qemu` carries ~10–20% per-pod CPU overhead vs.
runc. Acceptable for cc-sandbox sessions which are interactive
rather than throughput-sensitive. If a specific session needs
near-native performance, the operator can request `runc-kvm`
explicitly.

### Bootstrap flow

The flake's responsibility ends at "the cluster is up with all
platform components installed and Flux watching the dynamic
path." Concretely:

1. NixOS rebuild on erebonia activates `services.k3s` plus
   the bundled stack. Cluster API up; CoreDNS, metrics-server,
   kine+SQLite, kube-proxy, kube-router, flannel, Traefik,
   ServiceLB, local-path-provisioner running. RuntimeClass
   YAMLs (runc, runsc, kata-qemu, runc-kvm) from the manifests
   directory are applied.
2. k3s' HelmChart controller applies external-snapshotter
   (provides VolumeSnapshot CRDs) before democratic-csi.
   cert-manager comes up before any Certificate resource is
   evaluated. Kyverno comes up with its policies scoped to
   `woodpecker-builds` (no cluster-wide image-source rule that
   would block bootstrap).
3. Flux comes up and reconciles the dynamic-manifest path.
4. Workloads are added to the dynamic layer and reconcile in.

Bootstrap-ordering notes:

- **CRDs before CRs.** external-snapshotter ships
  VolumeSnapshotClass CRD; democratic-csi's chart references
  it. Order via `dependsOn` on the HelmChart resource, or apply
  the CRD via `manifests/` directly.
- **cert-manager before its consumers.** Traefik's TLS
  configuration uses Certificates; cert-manager must be running
  first. k3s' HelmChart can be ordered.
- **Admission policies after their consumers.** Kyverno
  installed early but its enforcing policies enabled only after
  the system is otherwise stable.

These aren't surprises; they're documented k3s patterns. But
they need to be in the platform declaration, not discovered.

No imperative bootstrap steps beyond `nixos-rebuild switch`.
Cluster platform state is a function of the flake's content,
the same way every other host in the homelab is.

## Dev environments as cluster workloads

The eventual home for edith and trista is the cluster, as
StatefulSets backed by PersistentVolumeClaims.

### Why this works (re-examining the previous "no" answer)

The earlier objections to running mutable NixOS as a Pod were:

- **kata-agent vs. systemd PID 1 cgroup conflict** (per
  `llm-notes/done/kata-cloud-hypervisor-migration.md`). Real, but
  applies only to `RuntimeClassName: kata-qemu`. Under
  `RuntimeClassName: runc` (the default for non-isolated
  workloads), systemd-as-PID-1 in a Pod works correctly — the
  cgroup is owned cooperatively the same way it is on a regular
  host. Production patterns like Coder, Gitpod, Codespaces, and
  the broader systemd-in-container ecosystem all rely on this.
- **Mutable nix store overlay issue** (microvm.nix +
  cloud-hypervisor). Real, but applies to overlay-based mutable
  stores, not to a real filesystem mounted at `/nix` from a PVC.
  The Pod's `/nix` is a regular filesystem on a CSI volume; no
  overlay tricks needed.

Neither objection holds for a runc-runtime Pod with a PVC. The
pattern is mature and well-supported.

### What it looks like

- **StatefulSet** of size 1 for stable identity per dev env
- **Base image**: minimal NixOS bootstrap built via
  `dockerTools.streamLayeredImage`, similar to
  `packages/claude-sandbox-image/`
- **PersistentVolumeClaims** for `/nix`, `/home`, `/etc/nixos`,
  and any other state directories
- **`RuntimeClassName: runc`** (no kata, no cgroup conflict)
- **systemd as PID 1** via the entrypoint
- **sshd** managed by systemd inside
- **Service + NodePort** exposes SSH; langport's nginx (or
  Traefik in TCP mode for SNI-routed SSH) proxies from the
  management zone
- **VolumeSnapshot** for periodic backups (replaces
  `incus snapshot`)
- **Resource limits** matching today's `limits.memory = "16GB"`

### What we lose vs. Incus

- **`incus exec` / `incus console` UX.** `kubectl exec` covers the
  shell case; the console-attach flow is less polished.
- **Live migration.** Possible with KubeVirt, not with plain Pods.
  Single-node anyway today.
- **`incus snapshot` granularity.** VolumeSnapshot is
  per-volume; Incus snapshots are per-instance. Adequate for
  backups, less granular for "I'm about to do something risky,
  let me snapshot."

### Bootstrap chicken-and-egg

If the cluster is broken and the operator's primary dev env lives
in it, debugging is harder. Mitigation: **migrate edith first;
keep trista on Incus on erebonia as the recovery dev env until
edith has run reliably for several months**. The existing
primary/backup pattern handles this naturally. Once edith is
proven, trista can migrate too.

## Static fleet and the shrinking-services dynamic

The static fleet is migrating to lighter equivalents (Keycloak →
Authelia, etc.). Plausibly 6–10 GB RAM and 100+ GB disk freed over
the next year.

**Should the freed resources go to the cluster?** Mostly no.
Cluster sizing should be driven by workloads, not by available
headroom. With virtio-balloon, the cluster's `mem` ceiling can be set
high (16 GB) without statically committing the memory. Actual
reservation is dynamic.

**Should new small services go in the cluster instead of getting
their own microvm?** Depends on the service:

- **Foundational, stateful, security-critical** (auth, DNS, PKI,
  registry) → microvm.nix. Per-service failure domain matters.
  Authelia stays in its own microvm.
- **Small, replaceable, ecosystem-supported** → cluster, once it's
  operating well. Things like ntfy, future small internal tools,
  kube-prometheus-stack components.

The crossover for this homelab is around 8–12 small services that
could go either way. Below that, microvm-per-service is fine. Above
that, aggregation in the cluster amortizes overhead. We're not at
the crossover yet.

## What about KubeVirt?

KubeVirt would let the static fleet run as `VirtualMachine`
resources inside the cluster, getting CSI snapshots and a unified
API. Considered and rejected for the static fleet because:

- Adds significant complexity (operators, CRDs, virt-handler
  daemonsets) for marginal benefit.
- microvm.nix is much lighter than KubeVirt VMs at this scale.
- Loses NixOS-native module declarations like
  `services.authelia-main.enable = true`.
- The static fleet is already isolated correctly; live migration
  isn't a homelab need.

The dev-environment migration path uses **Pods + PVCs**, not
KubeVirt VMs — Pods are sufficient, KubeVirt is overkill.

## Migration plan

Phased, with rollback-via-NixOS at every step. Previous tools stay
declared in the flake until the new pattern has proven itself.

### Phase 0 — Resource inventory and coexistence audit (prerequisite)

Before Phase 1 lands k3s on erebonia, document and verify:

- **Erebonia's actual resources.** Capture `free -h`, `nproc`,
  `lscpu`, disk capacity. Project workload sum: existing
  deployd + roer microvm (512 MB / 2 vCPU) + saint-arkh (4 GB
  / 4 vCPU when deployed) + trista (Incus VM) + k3s overhead
  (4–8 GB) + cluster workloads. Confirm headroom.
- **Coexistence audit.** Walk the table in "Coexistence with
  deployd during transition" above against the live state of
  erebonia. Verify each touchpoint:
  - containerd socket paths don't conflict (k3s under
    `/run/k3s/containerd/`)
  - CNI conflist directories (`/var/lib/rancher/k3s/agent/etc/cni/net.d/`
    for k3s, `/etc/cni/net.d/` for deployd)
  - bridge names don't collide (`cni0` for flannel,
    `deploy-dmz` for deployd)
  - kata config file `/etc/kata-containers/configuration.toml`
    pinned to a known version (kata-runtime nixpkgs version)
  - `boot.extraModprobeConfig` duplicate declarations resolved
    (deployd module's nested-KVM setting redundant with
    erebonia's; pick one)
  - Port allocations free: 6443, 10250, 10256, 8472
- **NixOS rollback verified.** Confirm boot menu has a known-
  good previous generation; document the rollback procedure
  for "Phase 1 broke erebonia" recovery.

### Phase 1 — k3s with split control plane on erebonia

Everything platform-level is declared in the flake; no manual
imperative steps. Phase 1 declares both the apiserver microvm
and the agent on bare-metal, plus the systemd ordering that
makes the agent wait for the apiserver to be ready.

**k3s server microvm (apiserver, controller-manager, scheduler,
kine+SQLite):**

- Microvm.nix guest on erebonia. Trails-themed name. ~2 GB
  RAM, 2 vCPU initially. cloud-hypervisor backend (matches
  fleet).
- `services.k3s` inside the microvm with `role = "server"`
  and `extraFlags = "--disable-agent"`.
- Bundled k3s defaults (CoreDNS, metrics-server, kine+SQLite,
  Traefik, ServiceLB, etc.) all enabled.
- HelmChart resources in `/var/lib/rancher/k3s/server/manifests/`:
  - `external-snapshotter` (must apply before democratic-csi —
    provides VolumeSnapshot CRDs)
  - `cert-manager` + step-ca ClusterIssuer
  - `democratic-csi` (zfs-generic-iscsi driver targeting
    liberl)
  - `kyverno` with ClusterPolicies scoped to
    `woodpecker-builds` namespace only
  - `flux` configured to bootstrap against the
    dynamic-manifest path
- RuntimeClass YAMLs (runc, runsc, kata-qemu, runc-kvm) in
  the manifests directory.
- One virtio-net interface on a controlled-exposure bridge
  (only reachable from erebonia and selected tailnet-attached
  clients via langport's proxy if remote kubectl is wanted).

**k3s agent on erebonia bare-metal (kubelet, kube-proxy,
containerd, CNI, all workloads):**

- `services.k3s` on erebonia with `role = "agent"`,
  `serverAddr = "https://<microvm>:6443"`, `tokenFile`
  pointing at a sops-managed shared token.
- gVisor's `runsc` binary on erebonia.
- kata-runtime binary (already present via deployd's module
  today; coordinate version pinning during the transition).
- iSCSI client tools (`pkgs.openiscsi`) on erebonia.
- containerd shim configuration registering `runsc` and
  `kata-qemu` (the agent's containerd template).

**Bootstrap ordering:**

```nix
systemd.services.k3s-apiserver-wait = {
  description = "Wait for k3s apiserver in microvm";
  wants = [ "microvm@k3s-server.service" ];
  after = [ "microvm@k3s-server.service" "network-online.target" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${pkgs.curl}/bin/curl --retry 60 --retry-delay 2 \
      --retry-connrefused --cacert <ca> https://<microvm>:6443/readyz";
  };
};
systemd.services.k3s = {
  wants = [ "k3s-apiserver-wait.service" ];
  after = [ "k3s-apiserver-wait.service" ];
};
```

microvm.nix's sd_notify integration over vsock ensures
`microvm@k3s-server.service` only completes when the guest
signals ready; the oneshot then verifies the apiserver itself
is responding; the agent waits for both.

**liberl-side requirements** (parallel work in Phase 1):

- NixOS module on liberl for iSCSI target (LIO/targetcli or
  scstadmin)
- Dedicated ZFS dataset hierarchy for cluster-allocated
  volumes
- Service user with `zfs allow create,destroy,snapshot,clone`
  on that hierarchy
- SSH or HTTP API endpoint for democratic-csi to issue ZFS
  commands; credentials in sops
- liberl's iSCSI portal reachable from cluster zone (router6
  forwardRule: cluster → liberl on TCP/3260)

**router6 cluster zone**, derived from network registry (use
`forHost` helpers, not hardcoded IPs — the previous example
hardcoded an incorrect IP for phantasma):

```nix
router6.zones.cluster = let
  net = pkgs.mmell.lib.data.network;
  forHost = name: (net.forHost name).host;
in {
  icmpEcho = "disable";
  accessTo = [ "internet" ];
  forwardRules = {
    network = [   # phantasma — DNS
      { proto = "udp"; daddr = (forHost "phantasma").ipv4; dport = 53; }
      { proto = "tcp"; daddr = (forHost "phantasma").ipv4; dport = 53; }
    ];
    dmz = [
      { proto = "tcp"; daddr = (forHost "creil").ipv4;    dport = 443; }
      { proto = "tcp"; daddr = (forHost "langport").ipv4; dport = 443; }
    ];
    management = [
      { proto = "tcp"; daddr = (forHost "tharbad").ipv4;  dport = 9090; }
      { proto = "tcp"; daddr = (forHost "liberl").ipv4;   dport = 3260; }  # iSCSI
      { proto = "tcp"; daddr = (forHost "liberl").ipv4;   dport = 22;   }  # democratic-csi mgmt
    ];
  };
  inputRules = [
    # Public-facing cluster services route via langport
    { proto = "tcp"; saddr = (forHost "langport").ipv4; dport = 30000-32767; }
  ];
};
```

**Apply:** `nixos-rebuild switch` on erebonia. If anything
goes wrong, `nixos-rebuild switch --rollback` or boot the
previous generation via systemd-boot.

**Validation:**

- **Microvm boots and apiserver is reachable.** After a fresh
  `nixos-rebuild switch` on erebonia:
  `systemctl status microvm@k3s-server.service` shows active,
  `systemctl status k3s-apiserver-wait.service` shows
  succeeded oneshot, `systemctl status k3s.service` (agent)
  shows active. Bootstrap ordering works.
- **kubelet registered with apiserver.** `kubectl get nodes`
  (run from within the microvm or via a host with kubectl
  pointed at it) shows erebonia's hostname as a Ready node.
- `kubectl get pods -A` — k3s system Pods (CoreDNS,
  metrics-server, kube-router, Traefik, ServiceLB,
  local-path-provisioner) plus cert-manager,
  external-snapshotter, democratic-csi, Kyverno,
  Flux all `Running` (scheduled on the agent node, erebonia)
- `kubectl get runtimeclass` — runc, runsc, kata-qemu,
  runc-kvm all present
- Test pod with `runtimeClassName: runsc` runs and is
  sandboxed (`cat /proc/version` shows gVisor kernel string,
  not erebonia's host kernel)
- Test pod with `runtimeClassName: kata-qemu` runs inside a
  KVM VM (`uname -r` shows kata's guest kernel, distinct from
  erebonia's)
- Test pod with `runtimeClassName: kata-qemu` can access
  `/dev/kvm` for nested workloads (the cc-sandbox use case)
- Test PVC against democratic-csi: provisions on liberl,
  binds, snapshots successfully via VolumeSnapshot
- Test Certificate request: cert-manager issues from step-ca,
  binds to a Secret
- Pod-to-pod, pod-to-host-deny-default, pod-to-internet-only-
  via-router6-allows behave as expected
- **deployd coexistence intact**: a deployd-managed container
  starts and runs correctly with k3s active; `roer`'s
  deployd-api still serves; existing kata workloads under
  deployd unaffected
- Hostile-test from Appendix A's checklist runs cleanly under
  `runsc`

**Phase 1 is complete when**: the cluster comes up cleanly
from a fresh `nixos-rebuild switch`, all the above validations
pass, and Flux is reconciling an (initially placeholder)
dynamic-manifest path.

### Phase 2 — First workload: the blog (or skip to Phase 3/4)

The blog was the v17 canonical "smallest first workload" but
it isn't a homelab priority. This phase is genuinely optional:
either build the blog if there's content to ship, or skip to
Phase 3/4 if there isn't. The cluster-side validation work
(Deployment + Service + Flux reconciler + cluster Traefik
routing) gets done in any first workload regardless; the blog
is just the lowest-stakes choice.

- Deployment + Service + Flux reconciler watching the content repo
  for image updates.
- Cluster-side Traefik routes `blog.*` to the Pod; langport's
  nginx (or SNI passthrough) forwards public traffic to
  erebonia's k3s ingress.
- Exercises the whole stack with the lowest-stakes workload.

### Phase 3 — Game server with CSI snapshot

- Pick the smallest game in the planned set (probably Minecraft).
- Use democratic-csi for the world volume.
- Validate suspend/snapshot/resume. This is the prototype that
  was originally going to live as the deployd iSCSI add-on.

### Phase 4 — CI runners

- Deploy Woodpecker CI server + the kubernetes backend
  (`WOODPECKER_BACKEND=kubernetes`). Per-pipeline-step pods
  with the security stack from Appendix A (gVisor RuntimeClass,
  PSS Restricted, NetworkPolicy, Kyverno admission). The
  feature roadmap names Woodpecker as the chosen CI system;
  the network registry's "Forgejo Actions" label for saint-arkh
  is stale and should be reconciled when this phase lands.
- Migrate any planned CI workflow into Woodpecker pipelines.
- Decommission saint-arkh's planned role; the network-registry
  allocation can be reclaimed or repurposed.

### Phase 5 — Migrate cc-sandbox to the cluster

**This phase moves forward in v18.** Earlier revisions deferred
cc-sandbox migration 12+ months on the theory that the cluster
needed to prove itself first. With v18's bare-metal pivot on
the same host cc-sandbox already runs on, the deferral isn't
worth its operational cost (a year of two orchestrators
competing for kata workloads on the same host). cc-sandbox is
also one of the strongest motivations for the pivot — its
current deployd nested-virt story is broken and bare-metal
kata-qemu (or runc-kvm) fixes it.

- Test cc-sandbox-shape workloads under `kata-qemu` first:
  spin up a test pod, validate `/dev/kvm` access works
  inside the kata VM, run a NixOS test VM to confirm nested
  KVM works.
- If kata-qemu's guest kernel can't handle nested NixOS-test
  VMs (the recurrence of the kata-kernel-nested issue),
  fall back to `runc-kvm`. Decide here.
- Reimplement the OIDC-authenticated Pod-creation flow as a
  small k8s controller, or extend `deployd-api` to talk to
  the k8s API instead of `deployd-helper`. (Either works;
  the latter is more reversible.)
- Run new cluster-side cc-sandbox in parallel with deployd-
  side cc-sandbox for a few sessions to validate.
- Cut over cc-sandbox's CLI to the new endpoint.

### Phase 6 — Decommission deployd

With cc-sandbox migrated, deployd has no remaining workloads.

- Remove `modules/deployd/` and `packages/deployd-{api,helper}`
  from the flake.
- Decommission `roer` microvm (deployd-api host).
- Reclaim the network allocations.

This phase ends the deployd cohabitation period (which was
weeks-to-months in v18 rather than the year envisioned in v17).
The kata config file at `/etc/kata-containers/configuration.toml`
is now solely owned by k3s' runtime; the coexistence audit
items collapse.

### Phase 7 — Migrate edith into the cluster

Earliest start: ~3 months into cluster operation, after Phases
2–4 have run reliably. (v17's "6 months" was anchored on
microvm-confined timing; bare-metal cluster matures faster
because there's no microvm-shaped surprise discovery.)

- Build a NixOS-as-Pod base image for edith via
  `dockerTools.streamLayeredImage`.
- Define a StatefulSet with PVCs for `/nix`, `/home`,
  `/etc/nixos`, and other state directories. PVCs backed by
  democratic-csi against liberl NAS (cross-host access works
  because PVCs are CSI-mediated, not host-local).
- **Cross-host PVC note**: parallel-run during cutover can't
  use the same RWX block volume from both the Incus edith
  (on calvard) and the Pod edith (on erebonia). Either:
  - Use NFS-backed (RWX) volumes during parallel run, switch
    to iSCSI (RWO) after cutover; or
  - Skip the parallel run; do a copy-then-cutover with a
    short downtime window.
- Run the new edith-pod for a few weeks. Validate that builds,
  dev workflows, sshd access, and the langport routing chain
  all work.
- Cut over by switching DNS / langport routing to the new
  edith. Keep the Incus edith declared (but stopped) for
  several more weeks as rollback option. Once confidence is
  high, remove the Incus declaration.

### Phase 8 — Reconcile trista's role

trista's role is ambiguous. The microvm-inventory classifies
it as a "Dev environment / task runner (backup)"; the actual
config (`hosts/erebonia/incus/guests/trista/default.nix`) uses
`profile = "dmz-vm"` and the network registry comment labels
it "SSH bastion (erebonia Incus VM)". The operator has
indicated trista is currently unused and can be left alone
until needed.

- **Default action: leave alone.** If trista isn't currently
  serving a workload, no migration work is needed.
- If a future bastion role is assigned to trista: keep it on
  Incus or migrate to the planned calvard-hosted bastion per
  Appendix B.
- If a future dev-environment role is assigned: migrate to a
  StatefulSet + PVCs the same way edith was migrated in
  Phase 7.

### Phase 9 — Decommission Incus (if/when appropriate)

- Once dev environments are in the cluster (and trista's role
  is resolved per Phase 8), evaluate whether Incus is still
  needed. If trista was the only remaining Incus guest, remove
  `common.incus` from calvard and erebonia.
- Reclaim the storage pool space.
- The flake gains one less control-plane module.
- Phase 9 may be deferred indefinitely if trista is kept on
  Incus or if a new use case emerges for Incus.

### Phase 10 — Multi-node expansion (when warranted)

The v18 pivot changes Phase 10's shape. With the cluster on
erebonia bare-metal, expanding to multi-node has two options:

- **Add calvard as a worker.** Workable but inverts the
  failure-domain story: dynamic cluster scheduling decisions
  would now affect calvard, which hosts the static fleet
  (Authelia, step-ca, Forgejo, observability stack, edith).
  An OOM-killer event or runaway pod on calvard would impact
  foundational services. **Not recommended** unless the
  static fleet has also been migrated.
- **Add a new host.** Provision additional hardware whose role
  is "cluster worker." Preserves the host-boundary failure-
  domain isolation v18 relies on. The new host has no static
  fleet to protect.
- **Stay single-node indefinitely.** For a homelab's workload
  scale, single-node erebonia is sufficient. Multi-node is a
  capacity-driven decision, not a maturity-driven one.

The original v17 Phase 10 ("add erebonia as worker to a
calvard-hosted control plane") is no longer applicable; erebonia
is already the cluster host. See **Appendix C** for the
topology evolution discussion, updated for the v18 shape.

### Phase 11 — Real HA (with or after Phase 10)

Add liberl as a third control-plane node, tainted against
workload scheduling. ~1 GB / ~1 vCPU control-plane-only
microvm; etcd state on liberl's btrfs SSD root.

In the v18 shape, Phase 11 is the more relevant HA step than
Phase 10 because it adds control-plane redundancy without
inverting the static-fleet isolation. Multi-node-via-new-host
+ liberl-as-third-voter is the canonical HA topology if/when
warranted.

Phases 10 and 11 are most valuable when done together — Stage
1 alone (multi-node) leaves the API as SPOF; Stage 2 alone
(3-voter etcd) leaves a SPOF worker. Together is when fault
tolerance materializes. See **Appendix C** for sequencing,
network requirements, and trade-offs.

### Sunset criteria, made explicit

- **Cluster proven**: at least one production workload (Phases
  2–4) running for 6+ months without recurring intervention.
- **Dev-env migration proven**: edith runs in the cluster for 3+
  months before trista migrates.
- **deployd retirement**: cluster has been the platform for new
  dynamic work for 12+ months with no rollback events.
- **Stop signal**: any phase that introduces recurring instability
  or operator pain triggers rollback (revert the relevant commits;
  the prior tool is still declared). Reassess.

## Risks and what could change the recommendation

- **deployd ↔ k3s coexistence debugging during transition.**
  Phases 1–6 have both running on erebonia. The audit
  checklist in the Architecture section identifies the
  touchpoints (containerd paths, CNI conflist directories,
  kata config sharing, bridge names, ports, kernel modules).
  Most are non-conflicts; the kata config file sharing is the
  real footgun. Mitigation: pin kata-runtime nixpkgs version
  during the transition; revisit when Phase 6 lands. If
  coexistence debugging gets noisy, accelerate Phase 6 to end
  the cohabitation period.
- **kata-qemu nested-KVM for cc-sandbox.** The kata-kernel-
  nested issue that originally drove cc-sandbox off kata in
  deployd may recur in the cluster's kata-qemu RuntimeClass.
  Phase 5 validates this explicitly before cutting over.
  Fallback: `runc-kvm` for cc-sandbox sessions, accepting the
  isolation downgrade for the sessions that need nested
  workloads. The cluster's bare-metal access to host
  `/dev/kvm` makes this the simple case (no nesting penalty).
- **gVisor + kata together adds maintenance surface.**
  Declaring both RuntimeClasses means tracking two
  separate runtime release cadences and two containerd shim
  configurations. v17's gVisor-only plan was simpler. v18
  accepts more surface for per-workload mapping (gVisor for
  CI, kata for cc-sandbox). Worth naming explicitly; budget
  ~bi-monthly check-in time for runtime updates.
- **k3s server microvm failures.** Apiserver crashes,
  kine/etcd corruption, controller-manager hangs — all
  contained to the apiserver microvm. Recovery: restart the
  microvm. Existing workloads on the agent continue running
  via kubelet's cached pod state; no new scheduling until
  apiserver recovers. NixOS rollback handles config errors.
  This is the major win from v18 → v19: control-plane
  failures don't take down the agent or its workloads.
- **k3s agent / kubelet failures on erebonia.** A kubelet bug
  or runaway pod can still affect erebonia bare-metal.
  Recovery: NixOS rollback for kubelet/containerd config
  errors; kubelet restart for runtime issues. Per-pod
  resource limits (Kyverno-enforced) bound runaway-pod
  damage. Less severe than v18 because at least the
  apiserver is independent and can be used for diagnostic
  queries during agent troubleshooting.
- **gVisor compatibility for CI workloads.** gVisor's userspace
  syscall implementation is mature but has gaps — some syscalls
  are unimplemented or behave subtly differently. Most CI
  workloads (compilers, package managers, standard build tools)
  work fine; very-low-level workloads can hit edge cases.
  Validate with the actual CI workload set before betting on it.
  Fallback: drop the affected job to `runc` + restricted PSS +
  NetworkPolicy; not as strong, still reasonable defense for the
  homelab threat model.
- **systemd-as-PID-1 in dev-environment Pods + PSS Restricted.**
  PSS Restricted blocks several mounts (`/sys/fs/cgroup` rw,
  `procMount: Unmasked`) that systemd typically wants. The
  bastion (Restricted, in Appendix B) and dev environments
  (Phase 5) cannot trivially share Pod policy if both run
  systemd as PID 1. Mitigation: dev environments may run with
  PSS Baseline rather than Restricted, with the trade-off
  explicitly recorded; or use a non-systemd PID-1 (a thin init
  + sshd directly). Validate during Phase 5 prototyping; don't
  assume Coder/Gitpod patterns transfer 1:1 (those products
  typically don't run systemd as PID 1).
- **cloud-hypervisor balloon support.** The original "use QEMU
  for balloon" decision was based on assumed maturity gap; v15
  recommends starting with cloud-hypervisor for consistency
  with the rest of the fleet. If balloon doesn't work cleanly
  in Phase 1, fall back to QEMU as a one-off pattern.
- **CSI iSCSI from inside a microvm — and from liberl as the
  target.** The microvm side is straightforward (`pkgs.openiscsi`).
  The liberl side is the harder part: a NixOS module for the
  iSCSI target, ZFS dataset hierarchy, service-user permissions,
  management endpoint. Validate the full lifecycle (provision,
  snapshot, restore, delete) against actual liberl in Phase 1
  before betting on it for game servers (Phase 3) or dev
  environments (Phase 5).
- **kine → embedded-etcd migration at HA expansion (Phase 11).**
  No `k3s migrate-datastore` command. Plan: snapshot SQLite,
  install fresh k3s with `--cluster-init` and embedded etcd,
  restore from snapshot via etcd's snapshot import, re-join
  nodes. Rehearse once before Phase 11 with a throwaway test
  cluster. Budget a brief outage. Not "off the critical path"
  — a real but bounded migration.
- **Forgejo registry capacity for CI throughput.** The plan
  assumes creil (Forgejo) handles CI build pushes, image GC,
  and signature verification. Forgejo's bundled registry is
  basic. May need replacement with Harbor or similar as Phase
  4 (CI runners) scales up. Defer until measured pressure.
- **Authelia OIDC compatibility with `kube-apiserver`.**
  Authelia's token shape, audience handling, and device-code
  flow may not match `kube-apiserver`'s OIDC verifier
  expectations exactly. Validate with `kubectl oidc-login`
  during Phase 1; if there's a mismatch, fall back to a small
  oauth2-proxy-shaped adapter or static kubeconfig with bearer
  tokens.
- **Dev-env migration risk.** edith is the operator's daily
  driver. Mitigation: parallel-run during cutover, keep trista
  on Incus until edith is proven, leave the Incus declaration
  live for several weeks of rollback window.
- **Operator skill investment.** k8s is a real learning curve,
  even with k3s' simpler bootstrap. The operator-facing UX for
  dev environments specifically (`kubectl exec` vs.
  `incus console`) is less polished. If after Phase 4 the
  operator's preference is clearly to keep Incus rather than
  consolidate, the recommendation should be re-evaluated —
  Phase 5 onward isn't forced.

## Alternatives considered

The plan picks specific tools at the platform layer. This
section names alternatives that came up across iterations
(some surfaced by independent review) and engages with each
honestly — what they'd look like, what they cost, why the
plan doesn't pick them.

### Talos as the cluster host's OS (instead of NixOS+k3s)

Talos Linux is an immutable OS designed for k8s. The cluster
microvm's NixOS layer would be replaced with Talos's machine-
config YAML. Smaller attack surface, OS designed for the role,
declarative-text configuration aligns with the LLM-readable
principle.

**Why not picked**: the rest of the homelab is NixOS;
introducing Talos for one guest fragments the management plane
(the operator now maintains both NixOS and Talos machineconfig
patterns). Loses access to NixOS modules inside the cluster
microvm — even though most of those are minimal for a k3s
host, they're still part of the consistent operator experience.
Worth revisiting if k3s-on-NixOS proves operationally
problematic.

### KubeVirt for dev environments (instead of Pod + PVC)

KubeVirt would let edith and trista run as `VirtualMachine`
resources inside the cluster — full VMs, libvirt+QEMU under
the hood, with snapshots via CSI and live migration when
multi-node. This is genuinely the workload shape KubeVirt is
designed for.

**Why not picked**: KubeVirt adds significant complexity
(operators, virt-handler DaemonSets, CRDs) for a feature set
the homelab doesn't need at scale — single-node anyway, no
live migration requirement, snapshots already covered by
democratic-csi for Pod PVCs. The Pod+PVC pattern with a
trade-off on PSS profile (likely Baseline rather than
Restricted) is lighter and adequate. Worth revisiting if the
Pod-with-systemd-as-PID-1 pattern hits problems Phase 5
prototyping can't resolve cleanly.

### Keep Incus permanently

The plan's Phase 7 decommissions Incus once dev environments
migrate to the cluster. The alternative: keep Incus
indefinitely as the right tool for mutable VM/container dev
environments, with k8s for ephemeral cattle workloads only.

**Why not picked (but barely)**: the consolidation argument
("3 control planes instead of 4") is meaningful but not
overwhelming. Incus is genuinely well-suited to dev
environments. The plan picks consolidation as preferred but
Phase 5–7 are explicitly framed as optional — if dev-env
migration to Pods proves operationally worse than Incus, the
right call is to stop at Phase 4 and accept Incus as a
permanent control plane. The plan should be read as "this is
the consolidation goal; deviation is acceptable when warranted."

### k3s with everything stripped (`--disable=traefik,servicelb,...`)

This was the main alternative the independent review pushed.
v15 substantially adopts it but in a milder form: keep most
k3s defaults rather than stripping them. Inside a microvm the
bundled stack doesn't conflict with anything; stripping
components just to disable them adds operational complexity
(things to remember to re-enable, divergence from upstream
default behaviors).

**Why the milder version**: the principle is "use the right
tool for the right layer," not "minimize bundled components."
k3s' bundled stack is the right tool inside the microvm; the
only component that genuinely doesn't fit (Traefik vs. host
Caddy) was deployd-specific anyway and goes away when deployd
sunsets.

### `services.kubernetes.*` (vanilla kubeadm-shape) on NixOS

Maximum NixOS-native: every k8s component declared in NixOS
modules.

**Why not picked**: violates the platform/dynamic boundary by
trying to pull cluster-API resources into the static layer.
Workload manifests should not live in the flake; this module
encourages that pattern. Also significantly more configuration
surface than k3s for no homelab-relevant benefit.

### k0s instead of k3s

The earlier revisions of this plan recommended k0s on the
basis that "k3s' bundled defaults conflict with our
infrastructure." That reasoning was anchored on a bare-metal
mental model and didn't survive the microvm-confinement
reframe. k0s is a fine distribution; in this homelab,
`services.k3s` is mature and `services.k0s` would have to be
written, so k3s wins on ergonomic grounds.

## Open questions deferred to implementation

Items the plan does not answer and shouldn't pretend to. Each
is a Phase-1 (or later) decision worth recording explicitly.

- **Cluster microvm persistent state.** Where does
  `/var/lib/rancher/k3s/server` live? On a btrfs subvolume on
  calvard's root pool? Via impermanence? What's the backup
  story for the kine SQLite database itself, separate from
  Velero (which only protects cluster state, not the datastore
  underneath it)?
- **PKI overlap.** k3s manages its own internal CA for
  apiserver/kubelet/etcd certs. step-ca on basel is the
  homelab's CA. Are these two trust roots, or does k3s' CA
  become a step-ca-signed intermediate? cert-manager handles
  workload TLS via step-ca; cluster-internal control-plane TLS
  is k3s-managed. Acceptable as two roots, just worth
  documenting.
- **Update cadences.** k3s pinned in the flake means manual
  bumps. What's the policy — track upstream within N weeks,
  bump on security advisory, etc.? Same question for
  cert-manager, democratic-csi, Kyverno, Flux. Probably
  Renovate or similar in the dynamic layer; not part of the
  platform.
- **Dynamic-manifest repo structure.** Monorepo path
  (`cluster/manifests/{infrastructure,apps}/`) or separate
  repo (`homelab-cluster-state`)? Affects blast-radius of
  reverts and CI pipeline complexity. Not load-bearing for
  Phase 1; decide before Phase 2.
- **Bootstrap-time observability.** If platform components
  fail during initial bring-up, before vmagent / Fluent Bit
  DaemonSet are running, what's the observability surface?
  Probably `journalctl -u k3s` inside the microvm, plus
  `kubectl describe` once the API is up. Worth a short
  runbook in `llm-notes/guides/`.
- **External-facing TLS strategy.** For public services
  hosted in the cluster (e.g., a public-facing blog), where
  does Let's Encrypt termination happen — langport's nginx
  (existing pattern) or in-cluster Traefik with a separate
  ACME setup? langport is simpler and matches existing patterns.
- **`kubectl` access path for the operator.** OIDC via
  Authelia + `kubectl oidc-login`? Static kubeconfig on edith?
  Both? Phase 1 chooses; document the answer.

## Appendix A: CI runner security architecture

CI runners execute arbitrary code (build scripts, dependencies,
contributor PRs). This is the workload class where "containers are
not a security boundary" matters most — a runc container is a
process-isolation boundary, not a security boundary against
hostile code. The following architecture treats untrusted-code
execution as the design constraint.

### Threat model

In scope:

- Compromised dependencies pulled by package managers (npm,
  PyPI, crates.io, etc.)
- Build scripts that attempt container or VM escape
- Contributor PRs containing hostile code
- Side-channel attacks on shared CI infrastructure
- Crypto miners or exfiltration via build steps

Out of scope (handle differently if needed):

- Nation-state APTs targeting the homelab specifically
- Supply-chain attacks on the cluster's own infrastructure
  (kubelet, containerd, Cilium binaries) — addressed by image
  pinning at the OS level, not at the CI layer

### Defense-in-depth stack

Six layers, each meaningful on its own.

#### 1. Per-step ephemeral pods, not long-lived runner daemons

Use Woodpecker's **kubernetes backend**
(`WOODPECKER_BACKEND=kubernetes`,
`https://woodpecker-ci.org/docs/administration/backends/kubernetes`).
Each pipeline step becomes a fresh Pod, run, then torn down.
Workspace is `emptyDir` — dies with the pod. No persistence
between steps; no persistence between pipelines.

Structurally better than the planned saint-arkh model (long-lived
runner daemon spawning local jobs). With per-step pods, a
compromised step cannot affect the next step or the next
pipeline.

#### 2. gVisor as RuntimeClass — the sandbox boundary

```yaml
spec:
  runtimeClassName: runsc
```

gVisor (`runsc`) is a userspace reimplementation of the Linux
syscall ABI. Containers under gVisor make syscalls into `runsc`
rather than into the host kernel; kernel-CVE exploits don't
have a target because the host kernel is never the addressed
syscall handler. The sandbox is destroyed at end-of-step.

This is the community-standard isolation tier for "k8s on VMs +
untrusted code" — used in production by Google Cloud Run, GKE
Sandbox, App Engine, GitHub-hosted Actions runners, and various
CI SaaS providers. It does **not** require nested KVM, which is
why it's a viable sandbox tier alongside kata-qemu (which
v18 also enables thanks to bare-metal on erebonia).

Performance: ~10–30% slower for syscall-heavy workloads
(dependency installation, file-heavy builds), near-bare-metal
for compute-heavy steps (compilers, linkers). Net comparable to
what kata-with-nested-KVM would have cost without the off-path
architectural complexity.

**Why not kata?** Kata in a microvm running on cloud-hypervisor
is genuinely off the common community path; the overhead is
similar to gVisor's but the architectural assumptions (nested
KVM, kata-runtime, kata containerd shim) compound dependencies
the platform otherwise wouldn't have. gVisor's threat model is
software-enforced rather than hardware-enforced — a real
difference, but for the homelab's threat model (build code from
your own repos, dependencies you mostly trust, occasional
contributor PRs), the software boundary is appropriate. Kata
remains available to add later if a workload genuinely needs
hardware-enforced kernel isolation; it's not part of the
baseline.

#### 3. Pod Security Standards (Restricted)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: woodpecker-builds
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

Restricted profile blocks: privileged containers, host
namespaces, host paths, host networking, capabilities other
than the explicit drop-list, root user, writable root
filesystem. Forces pod specs into the safe shape.

#### 4. NetworkPolicy + router6 — both must allow

Default-deny egress in the namespace; allow only what builds
actually need:

```yaml
# IPs derived from the network registry — example values shown for
# illustration; in practice these manifests should be templated from
# `lib.common.data.network.forHost`, not hardcoded
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ci-egress
  namespace: woodpecker-builds
spec:
  podSelector:
    matchLabels:
      ci.woodpecker/role: step
  policyTypes: [Egress]
  egress:
  - to: [{ ipBlock: { cidr: <creil-ipv4>/32 } }]      # git + registry
    ports: [{ protocol: TCP, port: 443 }]
  - to: [{ ipBlock: { cidr: <phantasma-ipv4>/32 } }]  # DNS (10.91.10.10)
    ports: [{ protocol: UDP, port: 53 }]
  - to: [{ ipBlock: { cidr: <zeiss-ipv4>/32 } }]     # attic cache
    ports: [{ protocol: TCP, port: 443 }]
```

**Templating note**: NetworkPolicy and router6 zone rules
share the same set of "what cluster needs to reach" facts. The
right pattern is to derive both from network registry helpers
in a single place, so a phantasma re-IP (e.g., during the
ongoing vMGMT VLAN split) updates both layers automatically.
Earlier revisions of this report hardcoded an incorrect IP for
phantasma (10.97.11.2 — phantasma actually lives at 10.91.10.10
in zone `network`); using the registry prevents this class of
error.

router6's `cluster` zone gates the same paths at the host
level. **Both must allow.** A misconfigured NetworkPolicy that
opens egress to `0.0.0.0/0` still hits router6's default-drop
for anything not in the cluster zone's allowlist.

The deliberate posture: **CI builds shouldn't pull directly
from public internet registries.** Mirror upstream packages to
creil / zeiss first; CI fetches from those. This gives a
security property (no surprise upstream code execution) and a
reliability property (CI doesn't break when npm.org has an
outage). Higher convenience trade is "let CI hit the internet";
the recommended posture here is the stricter one.

#### 5. Resource limits and admission policies

Per-step:

```yaml
resources:
  limits:
    cpu: "4"
    memory: "8Gi"
    ephemeral-storage: "20Gi"
  requests:
    cpu: "500m"
    memory: "1Gi"
```

Plus admission controllers (Kyverno or OPA Gatekeeper)
enforcing:

- `runtimeClassName` MUST be `runsc` in
  `woodpecker-builds`
- `image:` MUST start with `creil.internal/`
- No `hostPath`, no `hostNetwork`, no `privileged: true`
- Resource limits MUST be set

PSS covers most of this; admission policies add image-source
enforcement and the runtime-class requirement (PSS doesn't
constrain RuntimeClass).

#### 6. Secrets scoping

CI secrets that are dangerous if leaked (registry push tokens,
deploy keys, signing keys) need narrower scopes than "every CI
pipeline."

- **Per-pipeline-type secrets via Woodpecker's secret feature**,
  scoped by repo / branch / pipeline name. A PR-build pipeline
  doesn't get the production-deploy key.
- **External Secrets Operator** if secrets live in an external
  store; otherwise plain Kubernetes `Secret` resources mounted
  into specific step pods only.
- **ServiceAccount RBAC** so woodpecker-server's SA can create
  pods only in `woodpecker-builds`, nothing else.

### Architecture summary

```
woodpecker-system namespace:
  - woodpecker-server Deployment
  - Postgres StatefulSet
  - PSS: baseline (server itself is trusted)

woodpecker-builds namespace:
  - PSS: restricted
  - All step pods: runtimeClassName=runsc (gVisor)
  - Default-deny NetworkPolicy + explicit egress allows
  - Kyverno policies enforcing image source and runtimeClass
  - ResourceQuota capping total concurrent build CPU/memory
```

router6's `cluster` zone gates the cluster host's egress to
creil / zeiss / phantasma; NetworkPolicy gates per-pod egress
within those bounds.

### Comparison: saint-arkh planned vs. k8s + gVisor

| Property | saint-arkh (planned) | k8s + gVisor |
| --- | --- | --- |
| Runner-to-host isolation | microVM (KVM boundary) | microVM **plus** per-step gVisor sandbox |
| Step-to-step isolation | none — same runner host | each step is a fresh gVisor sandbox |
| Network policy granularity | host-level only | per-pod NetworkPolicy + host zone |
| Image source enforcement | manual | admission controller |
| Resource accounting | per-runner | per-step |
| Recovery on compromise | rebuild the whole VM | tear down one step pod |
| Architectural risk | bespoke runner setup | community-standard pattern |

The microVM still exists (the cluster's microvm), but it's
shared infrastructure. Each individual build is sandboxed by
gVisor inside it.

This replaces saint-arkh's planned role. The saint-arkh
allocation can be reclaimed once the cluster's CI workflow is
operational (Phase 4 of the migration plan).

### What this stack is NOT

The defense-in-depth here is correct for the realistic threat
model (untrusted build code, hostile dependencies, compromised
PRs). It is not a complete security architecture against:

- **Higher threat profiles** (nation-state APTs) would warrant
  additional layers: kata as a second-stage hardware-enforced
  sandbox (the layer above gVisor's software sandbox),
  mandatory image signing via cosign + admission policy,
  per-pipeline ephemeral credentials via Vault, more
  aggressive egress monitoring.
- **Misconfiguration**. Each layer is independently
  configurable and independently verifiable. Audit each layer;
  don't assume "we're using k8s" implies "we're secure." A
  step pod without `runtimeClassName: runsc` is just a runc pod
  — no gVisor sandbox. Admission policies must enforce this.
- **Data exfiltration via allowed channels.** A build step
  authorized to fetch from creil can also POST to creil if
  network policy permits TCP/443 bidirectionally. NetworkPolicy
  can scope this to specific endpoints, but DNS-based
  exfiltration through phantasma is structurally hard to
  prevent without DNS filtering at phantasma itself. Consider
  this when scoping policies.

### Validation checklist (before running untrusted code)

Before accepting external PR builds or running anything
hostile:

- [ ] `kubectl get runtimeclass runsc` returns a valid
  RuntimeClass
- [ ] PSS labels on the namespace enforce `restricted`
- [ ] Kyverno (or equivalent) policies are loaded and tested:
  reject a pod without `runtimeClassName: runsc` in the
  namespace
- [ ] NetworkPolicy default-deny is in place; test that a pod
  cannot reach `1.1.1.1:443`
- [ ] router6's `cluster` zone allows only the documented
  destinations
- [ ] ResourceQuota caps prevent a runaway build from
  consuming the cluster
- [ ] Secrets are scoped per pipeline type, not global
- [ ] Audit log + Hubble flow logs are flowing to Loki
- [ ] Hostile-test: deploy a pod that tries to escape (e.g.,
  attempts to mount `/proc/sys`, send raw packets, exec a
  known kernel exploit) and verify all attempts fail / are
  logged

The hostile-test is worth doing once. After that, automated
admission policy validation is what catches regressions.

## Appendix B: Jump box / SSH bastion

The planned SSH bastion (Step 4 in the feature roadmap, "Calvard
name TBD, Incus VM on calvard") replaces SSH access through
langport. If migrated to the cluster instead of deployed as an
Incus VM, it needs a security architecture similar in shape to
the CI runners (Appendix A) but with meaningful differences.

### How bastion threat model differs from CI runners

| Property | CI runner | Bastion |
| --- | --- | --- |
| Code running | Untrusted (PRs, deps) | Trusted (admin sessions) |
| Sensitive context | Build secrets, narrow scope | User SSH agents, broad pivot to homelab |
| Lifecycle | Ephemeral per-step | Long-lived |
| Inbound traffic | None | Port 22 from tailnet (or internet) |
| Multi-user concern | One job per pod | Multiple users on one bastion |
| Failure domain on compromise | One step's outputs | Lateral movement across homelab |

CI's stack is "isolate the workload from the host." The bastion's
stack is "isolate the host from a public-facing front-door, and
isolate users from each other." Different shape, overlapping
mechanisms.

### What carries over from Appendix A

- **`runtimeClassName: runsc`** (gVisor) — sandbox boundary
  between bastion and the cluster host. Bastion runs trusted
  code (admin sessions) but is public-facing, so defense-in-
  depth via gVisor against sshd CVEs and session-escape attempts
  is appropriate.
- **PSS Restricted profile** on the namespace — drops
  capabilities, blocks host namespaces, forces non-root.
- **Admission policies** (Kyverno/OPA) enforcing image source =
  creil and `runtimeClassName: runsc`.
- **NetworkPolicy + router6 dual-allow** for egress.
- **Resource limits and quotas.**

### What's different

#### Inbound traffic

CI runners have no inbound. Bastion has port 22 from outside the
homelab. Architecture:

- **Service of type `NodePort`** for port 22 → bastion pod.
- **Host-side TCP proxy** (caddy-l4 if Caddy is built with the
  L4 module, else nginx stream, else direct DNAT) forwards
  external 22 → cluster host's NodePort.
- **router6** allows inbound `<external>:22` → cluster host
  only via that path.
- **NetworkPolicy ingress** restricts which sources can reach the
  bastion pod's port 22 — at minimum, only the cluster host's
  interface.

If bastion access is **tailnet-only** (recommended), the inbound
surface shrinks dramatically: no public internet exposure, only
headscale/tailscale-attached clients. router6's `cluster` zone
gets `inputRules` allowing port 22 only from the tailnet zone.

#### Egress is much broader than CI

CI's egress is narrow (creil, zeiss, phantasma). Bastion needs:

- DNS (phantasma:53)
- SSH (port 22) to **most internal hosts** — the bastion's job is
  to be the jump-off point
- step-ca:443 if SSH certs are validated against it
- Authelia/Keycloak:443 for OIDC SSH auth (if used)

This is genuinely a bigger attack surface than CI: a compromised
bastion has more places to pivot to. Mitigation: limit which
**target hosts** the bastion can SSH to with explicit destination
IPs in NetworkPolicy + router6 forwardRules — not "all of management"
but specifically "the listed bastion targets."

#### User session isolation

Three options:

- **Shared bastion, Linux user separation.** Single Pod. Multiple
  authorized users sshing in get separate Linux UIDs. Simplest.
  Standard Linux user separation suffices for trusted users.
- **Per-user persistent pod.** Each authorized user has their own
  bastion Pod. Heavier; useful if mutual trust between users is
  low.
- **Per-session ephemeral pod.** Each SSH connection spins up a
  fresh Pod. Highest isolation, heaviest. Boundary / Teleport
  pattern.

For the homelab's user count (1–5 trusted), **shared bastion is
right.** If friends become SSH users (not just game servers),
revisit.

#### Persistence — stateless vs. stateful

- **Stateless**. No persistent home dirs. Each connection starts
  fresh. Log everything centrally. Most secure; loses convenience
  like persistent tmux.
- **Stateful**. PVC mounted at `/home`. Tmux sessions, shell
  config, file staging persist across connections. More
  convenient; larger compromise blast radius.

For a homelab admin bastion, **stateful is reasonable** —
persistent tmux for long-running operations is genuinely useful,
and the operator is the trust root anyway. PVC at `/home` with
regular VolumeSnapshots and the option to nuke and rebuild from
image if compromised.

For a friend-accessible bastion, **stateless** is the right call.

#### SSH certificate validation, not authorized_keys

Worth noting because it's the existing homelab pattern: the
bastion validates SSH cert principals against step-ca on basel,
with OIDC-issued user certificates. This means:

- Short-TTL certificates (hours, not forever)
- Revocation by stopping cert issuance, not by editing files
- Per-user audit via cert principal
- No long-lived authorized_keys files on the bastion

This is the right model on k8s as well. The bastion image bundles
step-ssh trusted-CA configuration; sshd's `TrustedUserCAKeys`
points at the step-ca SSH CA pubkey baked into the image.

### Architecture sketch (if deploying on k8s)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bastion
  labels:
    pod-security.kubernetes.io/enforce: restricted

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bastion
  namespace: bastion
spec:
  replicas: 1
  template:
    spec:
      runtimeClassName: runsc
      containers:
      - name: sshd
        image: creil.internal/bastion@sha256:...
        ports: [{ containerPort: 22 }]
        securityContext:
          readOnlyRootFilesystem: true
          capabilities:
            add: [NET_BIND_SERVICE]
            drop: [ALL]
        resources:
          limits:   { cpu: "2", memory: "2Gi" }
          requests: { cpu: "100m", memory: "256Mi" }
        volumeMounts:
        - { name: home,           mountPath: /home }
        - { name: ssh-host-keys,  mountPath: /etc/ssh/host-keys, readOnly: true }
      volumes:
      - name: home
        persistentVolumeClaim: { claimName: bastion-home }
      - name: ssh-host-keys
        secret: { secretName: bastion-host-keys }

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bastion-ingress
  namespace: bastion
spec:
  podSelector: { matchLabels: { app: bastion } }
  policyTypes: [Ingress]
  ingress:
  - ports: [{ protocol: TCP, port: 22 }]
    # `from:` empty/restricted to cluster host interface only

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bastion-egress
  namespace: bastion
spec:
  podSelector: { matchLabels: { app: bastion } }
  policyTypes: [Egress]
  egress:
  # IPs templated from network registry; values shown illustrative
  - to: [{ ipBlock: { cidr: <phantasma-ipv4>/32 } }]  # DNS (10.91.10.10)
    ports: [{ protocol: UDP, port: 53 }]
  - to: [{ ipBlock: { cidr: <basel-ipv4>/32 } }]      # SSH cert validation
    ports: [{ protocol: TCP, port: 443 }]
  - to: [{ ipBlock: { cidr: <authelia-ipv4>/32 } }]   # OIDC (Authelia replacing Keycloak)
    ports: [{ protocol: TCP, port: 443 }]
  # SSH targets — explicit allowlist of bastion-target hosts
  # (do NOT use whole-zone CIDRs; specific destinations only)
  - to:
    - { ipBlock: { cidr: <calvard-ipv4>/32 } }
    - { ipBlock: { cidr: <erebonia-ipv4>/32 } }
    - { ipBlock: { cidr: <liberl-ipv4>/32 } }
    # ... explicit list per registry
    ports: [{ protocol: TCP, port: 22 }]
```

router6 mirrors this on the host side — the `cluster` zone (or a
dedicated `bastion` sub-zone) gets `forwardRules` to
management/dmz/network on port 22, plus `inputRules` allowing inbound
22 from the tailnet zone → microvm:nodeport.

### Should the bastion actually go in k8s?

The bastion is **borderline** for k8s. It is:

- Long-lived (not the ephemeral case k8s shines at)
- Stateful (PVC-required for persistent homes)
- Network-policy-heavy (broad egress, careful ingress)
- Foundational (compromise = homelab pivot)

A microvm.nix guest with `services.openssh.*` and
`services.step-ssh.*` is a perfectly clean alternative — it
would live in the dmz zone alongside langport. The same per-service-
failure-domain reasoning that keeps Authelia / step-ca on
microvm.nix applies here.

#### The k8s case for bastion

- Cluster is already running (the migration plan stands up the
  cluster in Phases 1–4).
- Consolidation: one less microvm, one less NixOS module set to
  maintain.
- VolumeSnapshot for home directories is a clean backup story.
- If admin sessions ever benefit from being scheduled near
  cluster workloads (probably they don't), this aligns them.

#### The microvm.nix case for bastion

- **Failure-domain independence.** A broken cluster shouldn't
  also mean no SSH access to debug it. With bastion outside the
  cluster, "cluster broken → SSH to bastion → debug cluster"
  works. With bastion inside the cluster, you're in trouble.
- **Foundational character.** Auth, DNS, PKI, SSH ingress all
  live on microvm.nix. The bastion fits naturally there.
- **Simpler.** NixOS module config is more compact than the
  k8s manifest set above.
- **No new tooling.** Existing langport-style nginx-stream or
  caddy-l4 ingress patterns extend trivially.

#### Recommendation

**microvm.nix for the bastion.** The chicken-and-egg argument is
the most important — if the cluster goes down, you want SSH
access independent of the cluster to fix it. Same logic that
keeps trista on Incus during edith's migration applies
permanently to the bastion.

This is one place where the migration plan's consolidation goal should
be relaxed. The endgame management-plane count remains 3
(NixOS + microvm.nix + k8s); the bastion lives in microvm.nix
indefinitely.

If that recommendation is wrong, the architecture above is the
right shape for a k8s deployment. The decision is reversible
either way (NixOS + git).

## Appendix C: Cluster topology — single-node, multi-node, and HA

The migration plan starts the cluster as a single microvm guest on
calvard. The cluster's topology can grow over time as workloads
warrant. This appendix documents the natural evolution path and
when each step is worth taking.

### Stage 0 — Single-node (Phases 1–9)

k3s on erebonia bare-metal. All cluster workloads scheduled
there. Static fleet stays on calvard, untouched.

- Simplest. One NixOS host config to declare the cluster, one
  routes table.
- No HA. Cluster down ≡ erebonia down.
- Sufficient for the workload set the plan ships: blog, game
  server, CI runners (Woodpecker pods), cc-sandbox (after
  Phase 5), eventually edith.

This is where the v18 migration plan starts. Don't pay multi-
node costs before there's a workload reason.

### Stage 1 — Multi-node (Phase 10)

In the v17 framing this was "add erebonia as worker to a
calvard control plane." With v18 inverting the cluster host
(erebonia is now the control plane), Stage 1's shape changes.

#### Three options when expansion is wanted

- **Add a new host as a worker.** Best preserves the host-
  boundary failure-domain isolation v18 relies on. The new
  host has no static fleet to protect, so cluster scheduling
  decisions don't affect foundational services. This is the
  recommended option if Stage 1 is wanted.
- **Add calvard as a worker.** Possible but inverts the
  failure-domain story. The static fleet on calvard becomes
  scheduling-adjacent to cluster workloads. An OOM event or
  runaway pod on a calvard-as-worker affects Authelia,
  step-ca, etc. **Not recommended.**
- **Stay single-node indefinitely.** Often the right answer
  for a homelab. Multi-node is a capacity decision, not a
  maturity decision.

#### What this is and isn't

- **Workload distribution**, yes — if a new host is added.
  Burst capacity for CI can spread; long-running workloads
  can be node-affinitied to whichever host suits them.
- **HA**, no. Single control plane on erebonia is still SPOF
  for the API regardless of how many workers exist. Existing
  pods on other nodes keep running if erebonia dies (kubelet
  caches its assigned pod set), but no new scheduling.

#### Storage architecture matters here

This is the design decision that matters most. Plan for it in
Phase 1 even if you're single-node initially:

- **democratic-csi against liberl NAS** (NFS or iSCSI) for
  anything that needs cross-node access — game server world
  volumes, dev environment PVCs, StatefulSet state, anything
  that should be reschedulable.
- **Local-path storage** only for genuinely node-local
  workloads — CI step `emptyDir` workspaces (already
  ephemeral), build caches that can be regenerated.

Pods bound to local-path PVs must run where the PV lives
(nodeAffinity). Workable but defeats some of the multi-node
value, so reserve it for ephemeral state only.

#### Costs

- More cluster surface (two cluster hosts, two firewall
  configs).
- Inter-host CNI traffic via Cilium VXLAN. Performance is fine
  on a gigabit LAN; basically free on 10gig; degrades pod-to-
  pod connectivity on flaky links.
- New failure mode: inter-host network partition. Worker loses
  contact with control plane → existing pods keep running but
  no scheduling. Manageable but a mode to understand.

### Stage 2 — Real HA (Phase 11, often with Stage 1)

Add liberl as a third control-plane node, tainted so workloads
don't schedule there.

#### Why liberl is the right host

- **Always-on.** liberl is the NAS — uptime focus aligns with
  cluster uptime focus.
- **Spare cycles.** NAS workloads are I/O-bound; CPU and RAM
  have headroom.
- **Already hosts microvm guests** (bose, zeiss, ravennue) on
  the same btrfs SSD root. Adding a control-plane-only microvm
  follows the existing pattern.
- **Failure isolation from calvard and erebonia.** Three
  different physical hosts means three independent failure
  domains. Lose any one, the cluster keeps working.

#### Resource cost

| Component | RAM | CPU |
| --- | --- | --- |
| kube-apiserver | 200–500 MB | low |
| etcd | 100–200 MB | low |
| controller-manager | 100 MB | low |
| scheduler | 50 MB | low |
| kubelet | 50 MB | low |
| **Total** | **~500 MB – 1 GB** | **~1 vCPU** |

A 1 GB / 1 vCPU microvm on liberl is plenty.

#### Storage for etcd

Etcd writes its WAL synchronously. Recommended fsync latency
is <10ms p99; ideally <1ms. liberl's btrfs SSD root meets this
comfortably — SSD typically does <1ms even under load.

Btrfs CoW doesn't stress etcd's workload (small WAL appends,
periodic snapshots). Optional belt-and-suspenders:
`chattr +C` on the etcd data directory disables CoW for that
subtree only, eliminating any potential fragmentation of
pre-allocated WAL segments. Pure optimization, not required.

The control-plane microvm's persistent state lives on liberl's
SSD root via the existing microvm.nix pattern (same as bose /
zeiss / ravennue). No new storage architecture work.

#### What you tell the cluster

```yaml
# liberl's node spec (set by k3s server bootstrap; k3s applies the
# control-plane taint by default for server nodes)
spec:
  taints:
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule
```

Kubeadm applies this taint to control-plane nodes by default.
Workloads that don't tolerate it (which is almost everything)
won't schedule on liberl. Control-plane components (apiserver,
controller-manager, scheduler) explicitly tolerate it.

#### Network paths

router6 needs cross-zone forwarding for:

- **etcd peer**: 2380/TCP between all three control-plane nodes
- **etcd client**: 2379/TCP between all three control-plane
  nodes
- **apiserver**: 6443/TCP from all nodes (control-plane and
  worker) to all control-plane nodes
- **kubelet**: 10250/TCP from control-plane to all nodes
- **CNI overlay** (Cilium VXLAN): 8472/UDP between all nodes

Standard k8s firewall requirements; the `cluster` zone in
router6 needs the corresponding `forwardRules`.

#### Costs

- One more cluster host to maintain (3 instead of 2).
- liberl gains a cluster role on top of NAS. If liberl reboots
  for NAS maintenance (NixOS upgrade), the cluster loses one
  control-plane vote temporarily. Still has 2/3 quorum, fine —
  but it's a new dependency to think about.
- Bootstrap order matters. First node runs
  `k3s server --cluster-init`; other server nodes join via
  `k3s server --server https://<first>:6443 --token <token>`.
  Document the procedure in the runbook.

### Sequencing

The two stages are logically independent but worth most when
done together:

- **Stage 1 alone** (multi-node, single control plane) gets you
  workload distribution but leaves the API as SPOF.
- **Stage 2 alone** (3-voter etcd, single worker) gives you HA
  for the control plane while leaving workloads on a SPOF
  worker. Mismatched.
- **Stages 1 and 2 together**: workload distribution + real HA.
  This is the configuration where you actually get fault
  tolerance — lose any single host, the cluster keeps serving.

#### Recommended phasing

- **Phase 10** (multi-node): add erebonia as worker. Workload
  pinning via labels.
- **Phase 11** (HA): add liberl as third control-plane node.
  Switch apiserver clients to use an HA endpoint (round-robin
  DNS, or a small proxy).

These can be a single "go multi-host properly" phase if you
want. The two changes are independent enough to land
separately, but the value materializes when both are in place.

### When does this all become worth doing?

Don't expand from single-node until at least one of these is
true:

- CI burst capacity on calvard's cluster host hits its
  ceiling (RAM, CPU, or scheduling pressure)
- Game servers + dev environments + CI start fighting over
  calvard's resources
- deployd is sunset (Phase 9) and erebonia would otherwise be
  underutilized
- The cluster has become foundational enough that "fix it
  tomorrow" is no longer acceptable for control-plane outages

Until then, single-node on calvard is the right shape. The
multi-node and HA additions are reversible (revert the
relevant commits, the extra microvms shut down) and can be
introduced when warranted.

### Comparison to alternatives

- **Raspberry Pi as etcd voter.** Common homelab pattern; same
  idea but with separate hardware to maintain. liberl microvm
  is strictly better — same NixOS-managed declarative
  deployment as everything else.
- **External etcd cluster** (3 etcd-only nodes, separate from
  the k8s control plane). Overkill at homelab scale. k3s'
  embedded etcd (via `--cluster-init`) is what you want.
- **Accept SPOF on the single-node control plane indefinitely.**
  Reasonable choice if "fix it tomorrow morning" is acceptable
  for cluster operations. The HA microvm is small enough that
  it's worth doing eventually anyway.

## Appendix D: Ecosystem and tooling — what the cluster adds

The cluster is justified primarily by the use cases already
discussed (CI runners, game servers, blog, dev environments).
Beyond those, having a real k8s cluster opens up an ecosystem of
tooling that wasn't previously available in this homelab. This
appendix surveys what's actually useful at this scale, framed
honestly: most k8s ecosystem hype is overkill for a homelab; some
of it is genuinely valuable.

The framing is **what the cluster adds**, not what it replaces.
The static fleet stays where it is (per the recommendation); the
cluster opens up capabilities alongside it.

### Genuinely useful, install early

These would land in the platform declaration shortly after the
cluster is operational. High value, low operational cost.

- **vmagent + Fluent Bit DaemonSet + kube-state-metrics** —
  extending the existing push-mode observability stack
  (`llm-notes/done/observability-stack-migration.md`) into the
  cluster, not introducing a parallel Prometheus.
  - **vmagent** scrapes cluster-side targets (kubelet, cadvisor,
    kube-apiserver, controller-manager, scheduler, kube-state-
    metrics, per-workload metrics endpoints) and `remote_write`s
    to tharbad's vmauth → vmsingle.
  - **Fluent Bit as a DaemonSet** collects pod logs from
    `/var/log/containers` and ships to tharbad's Loki via the
    existing nginx/htpasswd ingestion path. Same agent, same
    auth pattern, same backend as the rest of the homelab.
  - **kube-state-metrics** (small footprint) exposes k8s object
    state (Pod phase, Deployment readiness, etc.) for vmagent.
  - Optionally **VictoriaMetrics Operator** for declarative
    `VMServiceScrape` resources (the VM analog of Prometheus'
    ServiceMonitor). Useful if you want per-workload scrape
    configs as manifests in the dynamic layer.
  - Why not **kube-prometheus-stack**: the homelab moved off
    Prometheus and Grafana for the foundational stack; bundling
    them back in just for the cluster reintroduces the
    components you intentionally replaced. Extending the
    existing push-mode setup is cleaner and matches the
    "lighter-weight components" direction.
- **cert-manager** with a step-ca issuer. Declarative
  `Certificate` resources with automatic renewal. In-cluster
  TLS becomes trivial; pairs cleanly with the existing step-ca
  on basel. Removes the per-microvm certificate-renewal cron
  patterns.
- **Velero** for cluster backup and disaster recovery.
  Declarative backups (manifests + PVC contents) to S3-
  compatible storage. liberl could host MinIO as the local S3
  endpoint; off-site backup to external S3 is a config flag.
  For game-server world snapshots and dev-environment home
  directories, this is genuinely better than building backup
  scripts per workload.
- **Secret distribution from sops-nix into cluster Secrets.**
  Earlier revisions claimed external-secrets-operator handles
  this; that's incorrect — ESO doesn't have a stable sops
  backend (its supported backends are Vault, AWS/GCP/Azure
  secret managers, etc.). Real options:
  1. **`sops-secrets-operator`** (third-party). Watches
     SopsSecret CRs in the cluster, decrypts using a key
     mounted into the operator pod, materializes as
     Kubernetes Secrets. Keeps sops as source of truth.
  2. **NixOS-decrypts-at-boot, mounts into cluster host.**
     The cluster host's NixOS layer uses sops-nix to
     decrypt secrets to a path on the microvm filesystem;
     a small in-cluster tool (or kustomize generator)
     materializes them as Secret resources at sync time.
     Tighter coupling to NixOS, simpler implementation.
  3. **Vault**, with secrets reflected from sops-nix. Real,
     standard, but adds Vault as a dependency. Probably
     overkill for homelab scale.
  Recommendation: start with option 2 (sops decryption at the
  microvm boundary), revisit if it gets unwieldy. Decide
  during Phase 1.
- **Cilium Hubble UI** for network observability — only
  applicable if the homelab eventually swaps flannel for
  Cilium (see Risks). With the chosen CNI (flannel + kube-
  router, Hubble isn't available; debugging falls back to
  `iptables -L` inside the cluster host and router6 audit
  logs on the host. Acceptable initially; revisit if
  observability gaps become painful.

### Useful when the matching workload appears

Install when there's a concrete reason; not part of the initial
platform.

- **CloudNativePG** (Postgres operator). HA Postgres with
  automatic backups and point-in-time recovery via WAL
  archiving. Worth pulling in if/when a cluster workload needs
  Postgres (Authelia? a future blog comments DB?). Removes the
  per-service "run Postgres yourself" pattern.
- **Argo Workflows** for scheduled and event-driven tasks.
  DAG-based workflow engine — think a more capable cron with
  proper task dependencies. For "weekly NAS scrub report,"
  "nightly backup verification," "rebuild blog when content
  changes," this replaces ad-hoc systemd timers + scripts.
- **Argo Events** for webhook-driven actions. External event
  (Forgejo webhook, Tailscale ACL change, etc.) → triggers an
  Argo Workflow. Useful for push-driven workflows.
- **actions-runner-controller** (or Forgejo-Actions equivalent).
  Autoscaling CI runner pods (Appendix A). Replaces saint-arkh's
  planned role with per-job gVisor isolation.
- **kvm-device-plugin** for `/dev/kvm` access in pods. Required
  if cc-sandbox migrates to the cluster (Phase 8); not needed
  before then.

### Available but probably not worth installing

Honest assessment: these are real tools, but they don't pay back
their operational cost at homelab scale.

- **KEDA** (event-driven autoscaling). Useful for queue-depth-
  driven workloads. Not relevant for the current workload set.
- **Service mesh** (Istio, Linkerd, Cilium Service Mesh). mTLS
  between services, traffic shaping, distributed tracing. Real
  value at hundreds of services; overkill at homelab scale.
- **Knative** (serverless on k8s). Request-driven pod spin-up.
  Overkill unless building HTTP services that need
  scale-to-zero.
- **Crossplane** (provision external resources via k8s API).
  Useful for managing cloud accounts; not relevant for an
  isolated homelab.
- **Tekton** (k8s-native CI/CD). Functionally similar to
  Woodpecker's k8s backend but heavier. Stick with Woodpecker
  unless you outgrow it.
- **Agones** (game server fleet management). Designed for
  session-allocated games (matchmaker assigns players to
  servers from a pool). Overkill for "one or two persistent
  servers running for weeks at a time." Plain StatefulSet +
  PVC + VolumeSnapshot covers your stated use case.

### Specific to the cc-sandbox-shape problem

The dev-environment-on-demand problem (cc-sandbox today, edith/
trista in the cluster post-migration) has off-the-shelf k8s
solutions worth knowing about:

- **Coder** (https://coder.com/). Productized cc-sandbox: OIDC
  login, templates define environment shapes, per-user
  workspaces as Pods (or KubeVirt VMs) with PVCs, idle-timeout
  shutdown, web terminal + SSH + IDE integrations, resource
  quotas, audit logs. Migrating cc-sandbox to Coder would gain:
  idle shutdown (saved cycles), templates, web access. Would
  lose: the hand-tuned cgroup/seccomp profile audited in
  `packages/deployd-helper/src/validation.rs`.
- **DevPod** (https://devpod.sh/). CLI-driven. Closer in shape
  to current cc-sandbox UX. More composable, less bundled.
- **Plain StatefulSet + PVC** (the dev-env migration plan). The
  default for edith/trista; doesn't require additional tooling.

Honest framing: cc-sandbox works; the security model is
auditable; migration to Coder/DevPod only makes sense if
specific features (idle shutdown, templates, web access) are
desired. The cluster *enables* this option without forcing it.

### Integrations with existing services

This is where the cluster adds the most concrete value to the
homelab — the existing services already have first-class k8s
integrations.

- **Authelia / Keycloak**: native OIDC for cluster auth (kubectl
  via OIDC plugin). Workloads also get OIDC via OAuth2-Proxy as
  a sidecar or admission-injected. Single sign-on extends into
  the cluster transparently.
- **step-ca on basel**: cert-manager has a step-ca issuer.
  Declarative `Certificate` resources, automatic renewal,
  automatic distribution as Secrets. Removes per-service
  certificate management.
- **VictoriaMetrics on tharbad** (current foundational metrics
  store, push-mode): cluster-side **vmagent** scrapes kubelet,
  cadvisor, kube-state-metrics, and per-workload endpoints, then
  remote_writes to tharbad via vmauth. With VictoriaMetrics
  Operator, per-workload scrape configs are declarative
  (`VMServiceScrape` resources in the dynamic layer).
- **Loki on tharbad**: container logs ship via the same Fluent
  Bit pattern used elsewhere in the homelab — DaemonSet
  collects from `/var/log/containers`, ships via the existing
  nginx/htpasswd auth path. No separate aggregation, no
  alternative log pipeline.
- **Perses on tharbad** (replaced Grafana): cluster metrics
  from vmagent → vmsingle are queryable via Perses dashboards
  same as host metrics. No separate dashboard tool for cluster
  observability. (Perses was selected specifically because
  YAML dashboard definitions in git are LLM-readable for
  diagnostic and configuration assistance — see the
  "LLM-assisted operations" section above. The choice is
  fitness-for-purpose for that workflow, not a bet on Perses
  succeeding as next-gen Grafana. Risk profile is "small
  ongoing dependency on Perses being maintained," not "needs
  to win a popularity contest.")
- **Alertmanager + ntfy on tharbad** (unchanged): cluster alert
  rules go to vmalert in the cluster (or stay on tharbad's
  vmalert with cluster metrics federated in), routed to
  Alertmanager → ntfy same as host alerts.
- **creil registry**: ImagePullSecrets standard. Kyverno
  admission policies enforce that only creil-hosted images are
  used (Appendix A).
- **Woodpecker CI** with the kubernetes backend: per-pipeline-
  step pods, gVisor-sandboxed, autoscaled (Appendix A). Hooks
  into Forgejo for repo events. Webhook-driven workflows via
  Argo Events
  for more complex pipelines.
- **Headscale (planned)**: there's a community
  headscale-operator for auto-registering cluster services as
  tailnet nodes. Niche but interesting if you want cluster
  workloads to appear directly on the tailnet.
- **NAS (liberl)**: democratic-csi for PVCs (already covered).
  VolumeSnapshot for declarative backup of stateful workloads.
- **Cilium Hubble** (only if Cilium is later adopted in place
  of flannel): flow observability across cluster workloads;
  would pair with router6's audit logging at the host level
  for end-to-end network visibility. Not part of the v1
  platform.

### Workflow patterns enabled

Beyond integrations with specific services, the cluster enables
workflow patterns that are awkward in the current architecture:

- **GitOps end-to-end.** Push to a git repo → Flux reconciles →
  workload updated. The blog example is canonical: content
  commit → CI builds image → manifest updated → Flux deploys.
  Push-to-deploy without manual intervention.
- **Event-driven actions.** Webhook fires → Argo Events triggers
  workflow → workload happens. Replaces hand-wired systemd
  timers + scripts for cross-service automation.
- **Declarative backup.** Velero `Backup` resources scheduled
  via cron-style schedules. Backup state is queryable via
  kubectl, not buried in script logs.
- **Per-environment promotion.** A workload can have dev /
  staging / prod variants in different namespaces, promoted via
  kustomize overlays + Flux. Useful if you ever want to test
  cluster changes without affecting production workloads.
- **Push-to-deploy CI/CD.** A Woodpecker pipeline builds an
  image, pushes to creil, updates a manifest in
  `cluster/manifests/` via git push, Flux picks it up, rolls
  out the new image. End-to-end automation without per-
  workload deploy scripts.

### What this enables that wasn't possible before

Concrete capabilities the cluster adds that the current
architecture doesn't have:

- **Auto-scaling under load** (CI runners, game-server pools if
  ever needed)
- **Horizontal scaling** (multiple replicas of a workload behind
  a Service)
- **Declarative volume snapshots** (Velero, VolumeSnapshot CRD)
- **Event-driven workflows** (webhook → action without writing
  custom HTTP handlers)
- **Idle-shutdown workloads** (Coder-style dev environments,
  Knative if ever needed)
- **Operator-managed stateful services** (CloudNativePG, etc.)
- **Per-namespace RBAC and ResourceQuotas** (multi-user / multi-
  tenant scenarios)
- **Service-mesh observability** (cluster-internal traffic
  metrics, traces — even without a full mesh)
- **GitOps-driven deploy** (push to deploy, with rollback by
  reverting commits)
- **Standard ecosystem of operators** (anything that exists as a
  Helm chart or operator is a `helm install` away — vs. writing
  a NixOS module from scratch for novel software)

### What the cluster does NOT do that the static fleet does

To be honest about the trade:

- The static fleet's per-service KVM-VM failure domain is
  stronger than the cluster's per-pod isolation. Cluster
  workloads under runc share the cluster host's kernel;
  workloads under gVisor add a software syscall boundary but
  are still less isolated than a microvm-per-service. The
  microvm boundary the cluster itself sits inside provides
  isolation between cluster workloads and the rest of the
  homelab; per-workload isolation inside the cluster is a
  weaker guarantee. This is fine for cattle-shaped workloads
  and not the right guarantee for foundational pets — which is
  why those stay as microvms.
- NixOS module ergonomics for stable services (`services.X.enable
  = true`) are often better than the equivalent Helm chart
  configuration. Module authors encode operational expertise.
- The static fleet is operable with standard Linux tooling
  (ssh, journalctl, systemctl). The cluster requires kubectl
  and ecosystem-specific tooling.
- Static services have fully-deterministic update cadence (your
  rebuild = your update). Cluster workloads can be set up the
  same way (pinned versions, manual reconciliation), but the
  default is more automated.

These trade-offs are why the static fleet stays where it is.
The cluster doesn't subsume the static layer; it complements it.

## Appendix E: Future directions enabled (not planned)

The migration plan describes specific workloads that justify
standing up the cluster (blog, game servers, CI runners, dev
environments). Beyond those, the platform makes a number of
concrete workflows tractable that aren't in the plan but
become discoverable. This appendix lists them — not as
commitments, but as documentation that future-you (or future
LLM-assisted exploration) can reference when a "could we do
X?" question comes up.

The pattern across all of these: the workflow exists today in
some painful form (or doesn't exist at all), and the platform
makes it routine. None of these are required; all are
discoverable.

### Multiplayer / fleet game-server hosting (Agones-style)

The current plan covers persistent single-instance game servers
(Phase 3). For "matchmaker assigns players to a server from a
pool of available servers," **Agones** provides the pattern:

- `Fleet` resource defines a managed pool of game servers
- `GameServer` CRD per server instance
- `GameServerAllocation` request to assign players to a ready
  server
- Built-in lifecycle states: `Starting → Ready → Allocated →
  Shutdown`
- SDK for game servers to self-report readiness and player
  status

Useful if friends ever want competitive sessions where the game
allocates servers on demand, rather than a fixed Minecraft
world running for weeks. Overkill for the current "weekly
play sessions on a persistent server" use case; trivially
addable when the use case shifts.

### Per-PR preview environments

Forgejo PR opens → Argo Events listens for the webhook →
triggers Argo Workflow → workflow builds the PR's image, pushes
to creil, applies a manifest to a per-PR namespace with the
new image → preview URL gets posted back to the PR.

Closes preview namespace on PR merge or close. ResourceQuota
caps total preview-environment footprint.

This is genuinely transformative for projects with frequent
PRs — you can click a link and see the proposed change running
before merging. Doesn't exist today (deployd doesn't do
preview environments); becomes routine on the cluster.

### Coder-style multi-user dev environments

Coder (or similar) provides:

- Web UI for trusted users to provision dev environments
- Templates per environment shape (a "claude-sandbox"
  template, a "rust-dev" template, a "data-analysis" template,
  etc.)
- Per-user persistent workspaces with PVCs
- Idle-timeout shutdown (workspace pauses when user
  disconnects, resumes on reconnect — significant resource
  savings)
- Web terminal + native SSH + IDE integrations
- Per-user/per-group ResourceQuota and audit logs

Useful if dev environments expand beyond the operator (friends
working on a project, transient collaborators, classes/
workshops). Today this would require building from scratch on
deployd; tomorrow it's a Helm chart.

### On-demand test infrastructure

"Spin up a 3-node test cluster to validate changes to the
homelab's own platform layer before applying them" — the
self-test version of the homelab.

Implementations:

- **k3d / KinD pods** running ephemeral mini-clusters inside
  the production cluster
- **KubeVirt VMs** for fuller fidelity (test changes to host
  NixOS configs without touching real hosts)
- Wrapped in Argo Workflows so "run the platform-change test
  suite" is a single command

Today the homelab has `tests/modules/` for NixOS VM tests;
adding cluster-side test infrastructure would extend the same
discipline to k8s changes.

### Webhook-driven home automation

Argo Events listens for:

- Forgejo webhooks (PR opens, push to main, release tags)
- Tailscale ACL changes (Headscale events)
- Home Assistant events (motion, time, presence)
- ntfy delivery confirmations
- External cron-style triggers (schedules)
- `inotify` on NAS paths (new media files)

Each can trigger an Argo Workflow that does something useful:
deploy on push, run a backup verification when a snapshot
completes, regenerate AdGuard blocklists on schedule, etc.

Today most of this is hand-wired systemd timers + scripts
scattered across hosts; the platform consolidates the pattern.

### Short-lived ad-hoc compute Jobs

"I need 16 vCPUs and 64 GB RAM for an hour to render this
video / re-encode a media library / train a small model / run
a parallelized data crunch."

Today this would mean either a static microvm (wasteful when
not in use) or running on the operator's workstation. The
platform makes it a `Job` + `PVC` that runs once, writes
output, and tears down. ResourceQuota at the namespace level
prevents the ad-hoc Job from starving production workloads.

Pairs naturally with KubeVirt VMs if the workload needs full-
OS fidelity rather than a container.

### Friend-facing services with multi-tenant isolation

Give a friend (or family member, or trusted external user) a
namespace with:

- ResourceQuota capping their CPU/memory/PVC usage
- NetworkPolicy isolating them from other namespaces
- RBAC limiting them to their own namespace
- Their own kubectl access via Authelia OIDC
- Their own workloads, on their own update cadence

This is the "give me a VPS" pattern, expressed as namespaces
rather than VMs. Headscale-attached friends get cluster
access; their workloads land in their namespace; they can't
affect anyone else.

Today the homelab doesn't have a clean answer for "let a friend
self-host a small thing on my hardware"; tomorrow it's a
namespace + a kubeconfig.

### Backup/DR drills via Velero

"Once a month, restore last week's backup to a test namespace
and validate it works."

Velero handles the mechanics; an Argo CronWorkflow schedules
the drill; results post to ntfy. Periodic verification that
backups actually restore (rather than the more common pattern
of "we have backups but never tested restores").

Today the homelab's backup story is per-service; the platform
makes test-restore-in-a-test-namespace a routine workflow.

### Image vulnerability scanning

Trivy operator (or similar) scans images at admission time and
periodically. Scan results expose as Kubernetes events;
Kyverno can block deployment of images with known critical
CVEs above a threshold.

Useful as the cluster scales beyond "just my own images" —
e.g., Helm charts pulled from upstream registries that we
don't fully control.

### Operator-managed Postgres for arbitrary services

CloudNativePG provides a `Cluster` CRD; declare it, get an HA
Postgres with automatic backups, point-in-time recovery, and
failover. Workloads use it as a regular Postgres.

Today every Postgres-needing service runs its own Postgres
process (Keycloak/Authelia, Forgejo, Headscale). Tomorrow
they could share an operator-managed cluster — or, more
incrementally, a workload that suddenly needs Postgres can
declare a `Cluster` resource without anyone running a
dedicated install.

### What this list isn't

These are workflows the platform *enables*, not workflows
that need to ship with v1. The right time to engage with any
of them is when there's a concrete need; the wrong time is
"because the platform supports it."

The list serves two purposes:

1. **Documentation for future exploration.** When a "could we
   do X?" question comes up, this is the index of "yes, here's
   how, here's the operator/chart/pattern that does it."
2. **Honesty about what's not in the migration plan.** The
   migration plan covers blog, game servers, CI runners, dev
   environments. Anything else listed here is a future
   discovery, not a deferred-but-planned commitment.

## Revision history

Reverse chronological — most recent revision first.

- v19 (this revision): split the cluster's control plane and
  agent across the microvm boundary on erebonia. **`k3s
  server`** (apiserver, controller-manager, scheduler, kine)
  runs inside a microvm; **`k3s agent`** (kubelet, kube-proxy,
  containerd, CNI, pods) runs on erebonia bare-metal.
  
  Why: the operator pointed out that v18's "all of k3s on
  bare-metal erebonia" approach exposed the kube-apiserver
  directly on the host, which doesn't match the homelab's
  pattern of confining API surfaces (deployd-api in roer,
  Authelia in messeldam, etc.) to microvm guests with
  controlled network exposure. v19 puts only the API surface
  in a microvm while keeping workloads on bare-metal — so
  cc-sandbox still gets direct `/dev/kvm` access, kata-qemu
  pods still run on native KVM without nesting, game servers
  still get native performance.
  
  Bootstrap concern resolved via microvm.nix's sd_notify
  integration: `microvm@k3s-server.service` waits for the
  guest to signal ready (vsock-based), then a host-side
  oneshot polls the apiserver `/readyz` endpoint, then the
  k3s agent service starts. All declared in NixOS; no manual
  sequencing.
  
  Changes:
  - Recommendation: split control plane (server-microvm +
    agent-bare-metal)
  - Architecture: "Cluster topology — split control plane"
    + "Bootstrap ordering via systemd socket notification"
  - "Why erebonia, not calvard": unchanged in substance
  - "What's lost vs. running in a microvm" → "Costs of the
    split, named honestly" — one microvm to maintain, ~10–30µs
    apiserver latency, agent failures still affect host
  - Phase 1: declares both the apiserver microvm and the
    agent on bare-metal, with the systemd dependency chain
    documented inline
  - Risks: replaced "Erebonia kernel panic = everything down"
    with separate bullets for "k3s server microvm failures"
    (small blast radius, recovered by restart) and "k3s agent
    failures" (still on host but at least apiserver remains
    independent for diagnostic queries)
  - Performance: added control-plane-path note (small,
    fixed overhead); workload path unchanged from v18
  
  This is the cleanest answer reached so far: preserves all
  of v18's workload-performance benefits while restoring the
  API-surface confinement that v17's microvm framing was
  trying to provide. The systemd-notify integration makes
  the bootstrap concern a non-issue.
- v18: pivot Phase 1 from "k3s in a microvm on
  calvard" to "k3s on erebonia bare-metal." Substantive
  architectural change; not just editing. The operator
  pointed out that:
  
  1. Erebonia is already the dynamic-compute host (runs
     deployd with kata as default today, nested-KVM enabled,
     hosts saint-arkh's planned CI role). Role-fit is real.
  2. router6 isn't on calvard or erebonia, so the "must be
     microvm-confined for mechanical isolation" argument
     never applied to either VM host — already conceded in
     v16.
  3. Bare-metal eliminates nested-virt penalties: kata-qemu
     becomes the canonical pattern (no microvm-on-cloud-
     hypervisor weirdness), cc-sandbox `/dev/kvm` access is
     direct (which fixes the broken-nested-virt story that
     drove cc-sandbox off kata in deployd).
  4. NixOS rollback is the recovery mechanism (every change
     boot-reversible without data restore). The skill-
     investment-isolation argument earlier revisions used as
     load-bearing isn't valued — the operator wants to do
     this right the first time.
  5. The workloads that v17's microvm-confinement was
     protecting (roer, saint-arkh, trista) are either being
     deprecated (roer, saint-arkh) or unused (trista). The
     blast radius of "Phase 1 breaks erebonia" is much
     smaller than v17 framed.
  
  Changes:
  - Recommendation: cluster runs on erebonia bare-metal.
  - Architecture: replaced "Microvm-confined or host-direct
    deferred decision" subsection with "Why erebonia, not
    calvard" + "What's lost vs. running in a microvm" +
    "Coexistence with deployd during transition" (audit
    table for the cohabitation period).
  - Performance: dropped virtio overhead row; per-runtime
    cost table only. cc-sandbox under kata-qemu now first-
    class.
  - RuntimeClasses: kata-qemu reopened as a first-class
    option (was rejected in v14 for the microvm-confined
    plan; bare-metal makes it the canonical pattern). cc-
    sandbox default moves from runsc to kata-qemu with
    runc-kvm as fallback if nested KVM issues recur.
  - Migration phase reordering: cc-sandbox migration brought
    forward from Phase 8 (v17) to Phase 5 (v18). deployd
    decommission becomes Phase 6 (was Phase 9). edith
    becomes Phase 7. trista reconciliation becomes Phase 8
    with default "leave alone." Incus decommission becomes
    Phase 9 (and may be deferred indefinitely if trista
    stays).
  - Phase 10 (multi-node): reframed away from "add erebonia
    as worker." Three options now: add a new host (best),
    add calvard (not recommended — inverts static-fleet
    isolation), stay single-node (often right).
  - Phase 0 added (resource inventory + coexistence audit)
    as Phase 1 prerequisite.
  - Risks updated: drop the microvm-vs-host deferred-decision
    bullet (decision made); add deployd-coexistence-
    debugging, kata-qemu nested-KVM for cc-sandbox, gVisor +
    kata maintenance surface, erebonia-kernel-panic-recovery
    via NixOS rollback.
  - Appendix C topology: Stage 0 is now erebonia bare-metal;
    Stage 1's "add a node" options reanalyzed.
  - Reference table at top updated.
  
  This is the third "earlier framing anchored on a context
  that didn't generalize" correction in this report's
  history (v11→v12 prom-stack, v13→v14 kata-tier, v17→v18
  microvm-confinement). The pattern is real; the repo's
  design enables checking it (host configs are one
  directory read away) but I didn't cross-check until the
  operator pointed it out. Lesson recorded.
- v17: editing pass to fix internal
  inconsistencies surfaced by independent editorial review.
  No architectural changes; the recommendation, principles,
  migration plan, and threat model are unchanged.
  
  Specific fixes:
  - Recommendation header dropped stale "(QEMU backend for
    memory ballooning)" — body has recommended cloud-
    hypervisor since v15.
  - Deleted the stale `### Why this rules out k3s` subsection
    that argued against the document's own current
    recommendation.
  - Replaced Cilium Helm-values block in dual-firewall section
    with prose accurate to flannel + kube-router (the v15
    chosen CNI).
  - Aligned the bundled-stack list across "Distribution: k3s"
    bullet, the bootstrap flow steps, and Phase 1 validation
    so all three name the same canonical components.
  - Replaced "host Caddy" references in trade-offs, Phase 2,
    Phase 5, and the static-baseline list with langport-
    routing language. Caddy was deployd-specific; with
    deployd sunset and bundled Traefik handling cluster
    HTTP routing, host Caddy is no longer part of the
    architecture.
  - Reconciled trista's role-ambiguity (inventory says dev
    env; code says dmz-vm; registry comment says SSH bastion).
    Phase 6 is now "Reconcile trista's role" rather than
    "Migrate trista similarly"; resolution is operator-facing.
  - Replaced kubeadm/k0s join-procedure language in Appendix C
    with k3s-equivalent commands (`k3s server --cluster-init`
    and `k3s server --server`).
  - Removed Hubble from "existing integrations" since flannel
    is the chosen CNI; Hubble is conditional on Cilium
    adoption.
  - Aligned CI tooling on Woodpecker (per the feature
    roadmap); Phase 4 now names Woodpecker explicitly with
    a note that the network-registry "Forgejo Actions" label
    is stale.
  - Fixed factual errors: "ardent" was used as if it were a
    standalone host (it's a transition DNS alias for zeiss);
    "monrain" was named as a microvm guest (it doesn't
    exist). Both replaced/removed.
  - Standardized zone naming on registry-canonical
    `network` / `management` / `dmz` (was sometimes
    `infra`/`mgmt`/`dmz` or `vMGMT`/`vDMZ`/`vINFRA`).
  - Reordered revision history to fully reverse-chronological.
  - Added Phase 10 / Phase 11 stubs to the migration plan
    pointing at Appendix C; the body previously forward-
    referenced these phases without listing them.
  - Removed dangling "Path B" references from the body
    (term remains in revision history).
  - Removed "v15 default" body reference; the body should
    describe current state, not name revisions.
  - Removed "(planned altair)" parenthetical for an
    undecided host name.
  - Added microvm-confined-vs-host-direct as an explicit
    bullet in the Risks list (it was discussed in
    Architecture but missing from the "what could change the
    recommendation" enumeration).
- v16: two updates from operator review.
  
  **Microvm-confined vs. host-direct reframed as a defensible
  choice rather than a forced one.** The operator pointed out
  (correctly) that router6 only runs on gateway devices —
  thebeyond is the router; calvard and erebonia are VM hosts
  that don't import router6 at all. The mechanical-isolation
  argument the plan leaned on doesn't apply on the proposed
  cluster host. Host-direct is technically viable; the residual
  arguments for microvm-confinement are failure-domain
  isolation, hard resource bounds, cleaner reset/teardown, and
  skill-investment isolation during the learning phase. The
  recommendation is now microvm-confined for Phases 1–4
  (learning phase, reduce blast radius), revisit at Phase 4+
  with operating experience to inform the choice. Either
  outcome works; the rest of the plan doesn't depend on which.
  
  **Added Appendix E: Future directions enabled (not planned).**
  Concrete workflow examples of what the platform makes
  tractable beyond the migration plan's scope — multiplayer
  game-server fleet management (Agones), per-PR preview
  environments, Coder-style multi-user dev environments, on-
  demand test infrastructure, webhook-driven home automation,
  short-lived ad-hoc compute Jobs, friend-facing services with
  multi-tenant isolation, backup/DR drills via Velero, image
  vulnerability scanning, operator-managed Postgres. Framed
  explicitly as discovery rather than commitment — the list
  documents what's discoverable, not what's deferred.
  
  Net: plan acknowledges its own architectural choices are
  sometimes more open than earlier framings suggested, and
  explicitly documents what's enabled-but-not-planned so future
  exploration has a starting point.
- v15: incorporated independent review
  findings and pivoted from k0s to k3s. Distribution change is
  the headline: with the cluster confined to a microvm, k3s'
  bundled defaults (flannel, Traefik, ServiceLB, CoreDNS,
  metrics-server, kine+SQLite, kube-router) don't conflict
  with anything host-level — they live in the cluster's
  network namespace, not the host's. The earlier rejection of
  k3s was anchored on a bare-metal mental model that didn't
  survive microvm-confinement. `services.k3s` is a mature
  NixOS module; this dissolves the "write a `services.k0s`
  module" engineering work the review flagged as the #1
  finding.

  Other v15 changes from review findings:
  - Dropped host-Caddy-as-cluster-ingress assumption (Caddy
    on host was a deployd-specific concern; with deployd
    sunsetting, the cluster's bundled Traefik handles HTTP
    routing).
  - cert-manager + step-ca ClusterIssuer now load-bearing
    rather than nice-to-have.
  - Fixed factual errors: phantasma is at 10.91.10.10 (zone
    `network`, VLAN 10), not 10.97.11.2; saint-arkh / ardent /
    monrain use cloud-hypervisor in the actual code despite
    microvm-inventory.md describing them as QEMU. Recommend
    cloud-hypervisor as the cluster-microvm backend (matches
    fleet pattern); QEMU as a fallback if balloon doesn't
    work cleanly.
  - **cc-sandbox isolation tier corrected**: moved from
    `runc-kvm` (default) to `runsc` (default) with `runc-kvm`
    as an opt-in per session for `/dev/kvm`-needing workloads.
    Previous framing gave the most-likely-adversarial workload
    the weakest isolation. Carry through Phase 8.
  - NetworkPolicy examples templated from network registry
    (with explicit "use `forHost`, not hardcoded IPs" note);
    Kyverno policies scoped to `woodpecker-builds` namespace
    only (cluster-wide image-source enforcement would deadlock
    bootstrap).
  - Expanded democratic-csi requirements: liberl-side iSCSI
    target NixOS module, ZFS dataset hierarchy, service-user
    `zfs allow` permissions, management endpoint. Real
    engineering work, not a checkbox.
  - Fixed external-secrets-operator + sops claim (ESO has no
    stable sops backend); recommended sops-decrypts-at-NixOS-
    boot pattern as default with sops-secrets-operator as
    alternative.
  - Bootstrap ordering specifics: external-snapshotter CRDs
    before democratic-csi; cert-manager before its consumers;
    Kyverno scoped policies before its enforcement.
  - kine→etcd Phase 11 migration documented as real
    bounded work (rehearse once, brief outage), not "off the
    critical path."
  - Added **Alternatives considered** section engaging with
    Talos, KubeVirt-for-dev-envs, Incus-permanently, k3s-
    stripped, services.kubernetes.*, k0s.
  - Added **Open questions deferred to implementation**:
    cluster persistent state, PKI overlap, update cadences,
    dynamic-manifest repo structure, bootstrap-time
    observability, public TLS strategy, kubectl OIDC.
  - Risks expanded: gVisor compatibility (kept), systemd-as-
    PID-1 + PSS Restricted (new), cloud-hypervisor balloon
    (new), CSI iSCSI lifecycle (expanded), kine→etcd (new),
    Forgejo registry capacity (new), Authelia OIDC
    compatibility (new).

  This revision incorporates a substantive independent review.
  Findings the plan now addresses dropped half on the k3s
  pivot; the rest are corrected in place. The plan is now
  meaningfully closer to ready-to-implement than v14 was.
- v14: replaced **kata** with **gVisor**
  (`runsc`) as the strong-isolation tier for untrusted-code
  workloads. The "kata in a microvm running on cloud-
  hypervisor" pattern is genuinely off the common community
  path; gVisor is what k8s operators actually use when nodes
  are VMs and stronger isolation than runc is wanted (Google
  Cloud Run, GKE Sandbox, App Engine, GitHub-hosted Actions
  runners, various CI SaaS providers). gVisor doesn't require
  nested KVM, eliminating the triple-KVM stack that was the
  weakest link in the prior plan. The platform baseline now
  declares `runc` (default) + `runsc` (gVisor for untrusted) +
  `runc-kvm` (for cc-sandbox-shape `/dev/kvm` access); kata is
  intentionally not declared but can be added later if a narrow
  use case warrants it. Performance ballpark is comparable
  (~10–30% syscall-heavy slowdown vs. kata's 10–20% nested-KVM
  CPU overhead) but architectural complexity drops
  significantly. Updated Architecture, Performance, Component
  picks, Bootstrap flow, Migration Phase 1 validation, Risks,
  Appendix A (CI runner security), Appendix B (bastion), and
  Appendix D (CI runner integration mention). Threat-model
  trade is honest: gVisor is software-enforced rather than
  hardware-enforced; appropriate for the homelab's threat
  model (build code from your own repos, mostly-trusted
  dependencies, occasional contributor PRs); not appropriate
  for "running known-malicious code from a determined
  attacker" — for which kata-on-bare-metal-k8s would be the
  community-standard answer, not kata-in-microvm. Yet another
  instance of the v11→v12-style postmortem: I should have
  surveyed the community pattern more carefully before
  recommending kata as the default isolation mechanism.
- v13: added a new top-level section,
  **LLM-assisted operations as a design driver**, naming the
  principle that informs several decisions throughout the
  homelab and this report. Configurations and operational
  state should live as LLM-readable text in version control,
  not as opaque runtime state mediated by web UIs or
  imperative tools. Documents where the principle already
  shows up (NixOS, llm-notes/ structure, network registry,
  Perses, cc-sandbox) and how it reinforces specific k8s
  decisions in this report (GitOps via Flux, platform
  components declared in NixOS, manifests in git, avoidance of
  mutable-runtime-state tools). Includes the v11 → v12
  postmortem as a captured failure-mode lesson — the repo is
  designed so the relevant context is one directory read away;
  the lesson is to actually use that design. Also updated the
  Perses mention in Appendix D to reflect the actual selection
  rationale (LLM-readable YAML in git) rather than implying
  Perses was a generic "next-gen Grafana" bet — the risk
  profile is "small ongoing dependency on Perses being
  maintained," not "needs to win a popularity contest."
- v12: updated Appendix D to reflect the
  current foundational observability stack
  (`llm-notes/done/observability-stack-migration.md`):
  VictoriaMetrics + Fluent Bit + vmauth + vmalert + Loki +
  Perses + Alertmanager + ntfy, with Prometheus and Grafana
  intentionally replaced. Removed the kube-prometheus-stack
  recommendation (which would have re-introduced the components
  the homelab moved off of). Replaced with the right pattern
  for this homelab: vmagent + Fluent Bit DaemonSet +
  kube-state-metrics, push-mode to tharbad's existing
  VictoriaMetrics and Loki via vmauth and the nginx/htpasswd
  ingest paths. Optional VictoriaMetrics Operator for
  declarative VMServiceScrape resources. Updated the
  integrations section to reference the actual current stack
  (VictoriaMetrics, Loki, Perses, Alertmanager, ntfy) instead
  of the deprecated Prometheus/Grafana naming.
- v11: added Appendix D — ecosystem and tooling
  additions. Surveys k8s ecosystem honestly, framed as "what
  the cluster adds to the homelab" rather than "what it
  replaces." Categorizes tooling as install-early (kube-
  prometheus-stack, cert-manager, Velero, external-secrets,
  Hubble UI), install-when-triggered (CloudNativePG, Argo
  Workflows/Events, ARC, kvm-device-plugin), or skip
  (KEDA, service mesh, Knative, Crossplane, Tekton, Agones).
  Documents specific cc-sandbox-shape options (Coder, DevPod)
  with honest assessment that current cc-sandbox works and
  migration is optional. Lists integrations with existing
  homelab services (Authelia OIDC, step-ca via cert-manager,
  Prometheus on tharbad, Loki, creil, Forgejo, Headscale, NAS,
  Hubble) and workflow patterns enabled (GitOps end-to-end,
  event-driven actions, push-to-deploy CI/CD). Closes with
  honest accounting of what the cluster does NOT do that the
  static fleet does, reinforcing that they complement each
  other rather than the cluster subsuming the static layer.
- v10: added the **platform vs. dynamic
  boundary** as a first-class section. Corrected an earlier
  framing error: in v5–v9 the report described Cilium / CSI /
  Kyverno / Flux as "things you install on top," implying they
  were dynamic-layer concerns. They are not — they are
  baseline platform capabilities. Reclassified them as
  NixOS-declared platform components, applied at cluster
  startup via k0s Helm extensions. Updated the component-picks
  section to make this explicit and updated migration Phase 1
  to remove all manual `helm install` steps. Fresh-install
  reproducibility ("`nixos-rebuild switch` produces a fully
  operational platform") is now the explicit success criterion.
  Made the rejection of vanilla `services.kubernetes.*` more
  decisive — it violates the platform/dynamic boundary by
  pulling workload concerns into the static layer; k0s does
  not. This change tightens the report's coherence
  significantly; future revisions should preserve the boundary.
- v9: added Appendix C — cluster topology
  evolution. Documents three stages: single-node (the starting
  shape, Phases 1–4), multi-node with calvard control plane +
  erebonia worker (Phase 10, workload distribution), and full
  3-voter HA with liberl as a control-plane-only node tainted
  against scheduling (Phase 11, real fault tolerance). Maps the
  topology onto existing host roles (calvard interactive,
  erebonia batch/CI, liberl always-on). Confirms liberl's
  btrfs SSD root is suitable for etcd. Recommends doing
  Phases 10 and 11 together since the value materializes when
  both are in place. Defers all of it until single-node hits a
  workload reason to expand.
- v8: added Appendix B — SSH bastion / jump-box
  security. Threat model contrast with CI runners (trusted code
  with sensitive context vs. untrusted code with narrow scope).
  Documents the architectural deltas: inbound traffic surface,
  much broader egress allowlist, multi-user isolation choices,
  stateless-vs-stateful trade, SSH-cert validation pattern.
  Includes a complete manifest sketch for k8s deployment if
  chosen. Recommends microvm.nix instead — the chicken-and-egg
  failure-domain argument (cluster broken → need SSH to debug)
  outweighs consolidation benefits. Carves out the bastion as
  one place where Path B's consolidation goal is deliberately
  relaxed.
- v7: added Appendix A — CI runner security
  architecture. Six-layer defense-in-depth for executing
  untrusted code (per-step ephemeral pods, kata RuntimeClass,
  PSS Restricted, NetworkPolicy + router6 dual-allow, resource
  limits + admission policies, scoped secrets). Documents how
  k8s + kata replaces the planned saint-arkh role with stronger
  per-step isolation. Includes an explicit validation checklist
  to run before accepting hostile inputs. Will be promoted to
  its own document under `llm-notes/specs/` once stable.
- v6: committed to **Path B** — phased migration
  of dev environments (edith, trista) into the cluster, with
  Incus eventually decommissioned. Switched the cluster guest's
  hypervisor backend to QEMU for memory ballooning (the
  motivating concern). Made the rollback-via-NixOS framing
  explicit at each migration phase. Endgame is three control
  planes (NixOS + microvm.nix + k8s) instead of four. Re-examined
  the previous "k8s is for cattle, not pets" framing — Pods +
  PVCs + `RuntimeClass: runc` is a mature pattern for dev
  environments, used by Coder/Gitpod/Codespaces.
- v5: integrated findings into a coherent recommendation. The
  microvm framing changed the recommendation from "stay" to
  "build new dynamic work on a cluster, leave existing things
  alone."
- v4: added mechanical-prevention section comparing rootless k8s
  to k0s-in-a-microvm. Microvm-confined deployment provides the
  same mechanical isolation as rootless without the rootless
  workload-breaking penalties.
- v3: added dual-firewall composition section. Showed that
  "router6 authoritative, CNI additive only" is achievable in a
  shared kernel with discipline, at the cost of ~1.5x debug
  surface.
- v2: fresh-eyes rewrite — recommended staying, 60/40. Conceded
  k8s ≠ k3s, kubelet+containerd+kata is better-supported, operator
  ecosystem fit is real for CI runners and CSI.
- v1: initial pass — recommended staying, ~90/10. Anchored too hard
  on the prior k3s rejection and treated the kata-cgroup decision
  as authoritative for the orchestration question (it isn't).
