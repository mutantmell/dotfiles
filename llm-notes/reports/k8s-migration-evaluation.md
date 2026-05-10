# Kubernetes Migration Evaluation

Date: 2026-05-09 (v15 — see revision history at end)

## Question

Should we replace the dynamic-container layer (`deployd`,
single-host on erebonia) with a Kubernetes-based runtime? If yes,
what shape should the deployment take? Could it replace any static
microvm guests or the Incus dev-environment hosts?

## Recommendation

**Stand up a Kubernetes cluster inside a microvm guest (QEMU backend
for memory ballooning). Build new dynamic workloads on it. Migrate
the existing Incus dev environments (edith, trista) into the cluster
once it has matured. Leave the static microvm.nix fleet alone.
Sunset deployd once the cluster has proven itself.**

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
| Blog (planned) | — | k8s | First cluster workload; canonical Deployment + Flux pattern |
| Game servers (planned) | — | k8s | CSI VolumeSnapshot replaces the custom iSCSI add-on |
| CI runners (saint-arkh deferred) | — | k8s | Runner controller + per-job gVisor-sandboxed pods |
| Claude sandboxes | deployd | k8s eventually | Stay on deployd until cluster proven; migrate as part of deployd sunset |
| Dev environments (edith, trista) | Incus | k8s | StatefulSet + PVC; migrate one at a time after cluster proves out |
| Authelia and other small foundational services | microvm.nix | microvm.nix | Per-service failure domain still wins for foundational state |
| Static fleet (Forgejo, Jellyfin, Prometheus, etc.) | microvm.nix | microvm.nix | Don't migrate what works |

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
- **kubelet+containerd+kata is the better-supported integration
  path** than nerdctl+containerd+kata. Most of the integration
  friction with kata in deployd lives in the nerdctl glue layer,
  not in containerd or kata themselves.
- **Operator ecosystem fit is real** for CI runners (autoscaling
  runner controllers like ARC) and game servers (CSI
  VolumeSnapshot vs. building a custom iSCSI add-on).
- **Microvm-confined deployment** mechanically isolates the cluster
  from router6 — same principle as every other isolated service in
  this repo. The host firewall is unreachable across the hypervisor
  boundary regardless of what the CNI does.
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
- microvm.nix guest declarations including the cluster microvm
- k3s as a NixOS service inside the cluster microvm
  (`services.k3s`) — version pinned, config rendered from NixOS
- **k3s with bundled defaults** (flannel, Traefik, ServiceLB,
  CoreDNS, metrics-server, kine+SQLite, kube-router) — declared
  via `services.k3s` and configured from NixOS
- **k3s HelmChart resources** declaring cert-manager (with
  step-ca ClusterIssuer), external-snapshotter, democratic-csi,
  Kyverno, Flux — applied automatically at cluster startup, all
  chart versions and values pinned in the flake
- **RuntimeClass YAMLs** for runc / runsc / runc-kvm in k3s'
  auto-apply manifests directory
- **gVisor's `runsc` binary**, containerd shim configuration in
  k3s' containerd template, and iSCSI client tools inside the
  cluster microvm — host-level prerequisites the cluster relies
  on
- router6 zones (cluster zone with explicit egress allows)
- Host Caddy ingress configuration (NodePort proxying)
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

### Why this rules out k3s

Different reason. k3s' bundled defaults (Traefik, ServiceLB,
flannel, local-path) are platform decisions made for you. Some
of them (flannel, ServiceLB) actively conflict with the
homelab's existing platform decisions (Cilium, host Caddy
ingress). The philosophy is right; the bundle is wrong for this
homelab.

### Fresh-install reproducibility

The principle implies a specific test: **a completely fresh
install must produce a fully operational platform with no manual
steps.**

1. `nixos-rebuild switch` on the cluster's host
2. Cluster microvm provisions and boots
3. k3s starts with its bundled stack (flannel, Traefik,
   CoreDNS, metrics-server, kine+SQLite, kube-router)
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

### Run the cluster inside a microvm guest

The cluster's control plane and kubelet run inside a single
microvm.nix guest, the same way `roer` runs deployd-api today.
Pods are processes inside that guest's kernel. The host sees one
VM with one virtio-net interface and some virtio-blk traffic.

Pods inside the cluster run under runc by default. For workloads
that need stronger-than-runc isolation (untrusted code: CI step
pods running build scripts and dependencies; eventually anything
similar) — the cluster uses **gVisor** (`runsc`) as the
isolation tier. gVisor is a userspace reimplementation of the
Linux syscall ABI: containers under gVisor make syscalls into
`runsc` rather than into the host kernel, so kernel-CVE exploits
have no target. No nested-KVM dependency, no triple-KVM stack.

Kata is **not** the default isolation mechanism in this plan. The
"kata in a microvm running on cloud-hypervisor" pattern is
genuinely off the common community path; gVisor is what k8s
operators actually use when nodes are VMs and stronger isolation
than runc is wanted (Google Cloud Run, GKE Sandbox, App Engine,
many CI services). Kata sees production use primarily on
bare-metal k8s clusters where the nested-KVM concern doesn't
apply, or for workloads that need `/dev/kvm` as a feature (not as
isolation). Kata could be added to this cluster later if a narrow
use case warrants it, but it isn't part of the platform baseline.

### Hypervisor backend

microvm.nix supports multiple hypervisor backends. **Every
existing guest in this repo uses cloud-hypervisor** — the
microvm-inventory.md description of saint-arkh / ardent /
monrain as "microvm (QEMU)" is stale; verified against
`hosts/*/microvm/guests/*/microvm.nix`. So whatever backend the
cluster guest uses will be either "the same as everything
else" (cloud-hypervisor) or "the first guest to use a different
backend" (QEMU).

For memory pooling with edith specifically — the original
motivation for considering QEMU — the trade is:

- **cloud-hypervisor**: matches existing pattern, faster boot,
  smaller idle footprint. Has virtio-balloon support in recent
  versions but the microvm.nix integration is less battle-
  tested. For a long-running cluster guest, "less battle-
  tested balloon" is acceptable risk; worst case is the
  balloon doesn't reclaim and we set a smaller `mem` ceiling.
- **QEMU**: mature virtio-balloon, but introduces a new
  hypervisor backend in the repo. ~50–100 MB more idle
  overhead, ~5s vs. ~200ms boot.

**Recommendation: start with cloud-hypervisor** and validate
balloon behavior in Phase 1. If balloon doesn't work well, fall
back to QEMU as a one-off pattern for the cluster guest. The
boot-speed cost of QEMU is genuinely irrelevant for a guest
that lives for months; only the "first QEMU guest" pattern-
introduction cost is real, and it's small. This is a Phase-1
decision, not an architectural one.

### Why microvm-confined rather than on-host

Running the cluster in a guest VM:

- **Mechanically prevents the cluster from touching router6.** The
  microvm has its own kernel and its own `nf_tables`. The host's
  `nf_tables` is unreachable across the hypervisor boundary — not
  a syscall question, a hardware question. No CNI can install
  rules that affect router6 because there's no path. Stronger than
  rootless k8s (which has user-namespace edge cases) and stronger
  than convention.
- **Lets the CNI work normally.** Inside the microvm, kubelet
  *is* root, so any CNI works at full feature set — k3s'
  bundled flannel + kube-router NetworkPolicy is enough for
  this homelab; Cilium with eBPF is available later if its
  features become worth the additional configuration. Avoids
  the 20–50% network penalty of rootless slirp4netns/pasta, the
  broken CSI iSCSI story, and the unproven kata-rootless path.
- **Reduces the dual-firewall debug surface** to "one firewall per
  kernel, debugged in that kernel's tooling."
- **Reversible.** A failed cluster is one microvm to destroy. The
  static fleet, deployd, Incus, and the host are unaffected.
- **Already the standard pattern** in this repo (~13 isolated
  services as microvm guests) and in the broader community
  (managed cloud k8s, vSphere/Tanzu, Proxmox+Talos).

### Performance

By layer:

| Layer | Overhead |
| --- | --- |
| KVM CPU (hardware-assisted) | 1–3% |
| virtio-net | ~5% throughput, +10–30µs latency |
| virtio-blk / virtiofs | 5–10% |
| gVisor (runsc) for sandboxed pods | ~10–30% on syscall-heavy workloads, ~equal on compute-bound |
| Nested KVM (only inside cc-sandbox pods running nested NixOS-test VMs) | additional 10–20% CPU within that pod |

For the named workloads:

- Blog: invisible.
- CI runners under gVisor: ~10–20% slower than bare-metal for
  syscall-heavy steps (dependency installs, file-heavy builds);
  near-bare-metal for compute-heavy steps (compilers, linkers).
  Comparable in net to what kata-with-nested-KVM would have cost,
  without the nested-KVM dependency.
- Claude sandboxes: 5–15% slower than bare-metal runc once
  migrated. (Stays runc + kvm-device-plugin for `/dev/kvm`
  access.)
- Game servers under runc: ~5% network, ~3% CPU. Imperceptible to
  players.
- Dev environments under runc: identical to today (edith already
  runs as an Incus container with similar overhead).

Dramatically better than rootless k8s and similar to running any
other microvm guest. Notably, **no nested KVM is required for the
isolation model** — that requirement was specific to a kata-based
approach and goes away with gVisor.

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
    mgmt = [
      { proto = "tcp"; daddr = tharbad.ipv4;  dport = 9090; }
    ];
    infra = [
      { proto = "udp"; daddr = phantasma.ipv4; dport = 53; }
      { proto = "tcp"; daddr = phantasma.ipv4; dport = 53; }
    ];
  };
  inputRules = [
    # Caddy on the host fronts the cluster via NodePort range
    { proto = "tcp"; saddr = langport.ipv4; dport = 30000-32767; }
  ];
};
```

In Cilium (Helm values):

```yaml
kubeProxyReplacement: true
hostFirewall:
  enabled: false
ipam:
  mode: kubernetes
tunnelProtocol: vxlan
bpf:
  masquerade: true
ingressController:
  enabled: false
gatewayAPI:
  enabled: false
```

NetworkPolicy resources further restrict which pods may talk to
which destinations. NetworkPolicy is structurally
**deny-after-allow**: it can only subtract from what the underlying
network already permits. **router6 is the ceiling**; the CNI cannot
grant connectivity that router6 denies.

### Trade-offs to accept up-front

- **Pods masquerade to the microvm's IP at egress.** router6 sees
  microvm-IP-as-source for all pod traffic; per-pod policy lives
  in NetworkPolicy.
- **`Type=LoadBalancer`, MetalLB, hostPort, and CNI-native ingress
  controllers are off-limits.** They assume host firewall control
  we don't grant. Use `ClusterIP` + `NodePort` and front with the
  existing host Caddy. (This matches today's deployd model.)
- **Drift risk.** An operator adds a NetworkPolicy that opens
  egress to something router6 hasn't been told about; developers
  see unexplained drops. Failure mode is fail-closed (good) but
  annoying. Mitigation: maintain a single doc that lists every
  "cluster needs to reach X" requirement and the corresponding
  rule in both layers.

## Platform components — all NixOS-declared

Each of these is declared in the cluster microvm's NixOS
configuration and applied at cluster startup via k3s' bundled
mechanisms (HelmChart CRD, `manifests/` auto-apply directory).
None require manual post-install steps; a fresh
`nixos-rebuild switch` produces a fully operational platform.

- **Distribution: k3s** (`services.k3s` from nixpkgs — mature,
  maintained module). Bundles the boring infrastructure we need
  (CoreDNS, metrics-server, kine+SQLite, kube-proxy) and a
  default ingress/CNI/storage stack that, **inside the cluster
  microvm**, doesn't conflict with anything host-level. The
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
  nginx (or via SNI passthrough → cluster microvm:443 →
  Traefik). Tailnet-only services route directly to cluster
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
  not Helm).
  - `runc` (default) — trusted code: foundational service
    workloads, the blog, game servers
  - `runsc` (gVisor) — untrusted-or-adversarial code:
    CI step pods, **and cc-sandbox** (revised from prior
    revisions; see "cc-sandbox isolation tier" below).
    Installed via the gVisor containerd shim configured in
    k3s' containerd template; declared at the OS level in the
    cluster microvm. RuntimeClass YAML in the auto-apply dir.
  - `runc-kvm` — runc + kvm-device-plugin for the *narrow* case
    of cc-sandbox sessions that legitimately need `/dev/kvm`
    access for nested NixOS-test VMs, opted into per-session
    rather than per-workload.
  - **Kata is intentionally not declared.** Off the common
    community path inside a microvm; can be added later if a
    workload needs hardware-enforced kernel isolation
    specifically.

### cc-sandbox isolation tier — corrected

Earlier revisions had cc-sandbox migrate to `runc-kvm` based on
its `/dev/kvm` requirement. That gave the workload most likely
to be coaxed adversarial via prompt-injection (Claude executing
arbitrary code on the operator's behalf) the **weakest**
isolation in the cluster, while CI on `runsc` got the strongest
sandboxed tier. That ranking is inverted.

Corrected approach:

- **Default cc-sandbox sessions: `runsc` (gVisor)** — same
  isolation tier as CI runners. Sufficient for most sessions
  (LLM coding work, builds that don't need nested KVM).
- **`/dev/kvm`-needing sessions: `runc-kvm`, opted in per
  session.** When the operator requests a session that runs
  NixOS test VMs, cc-sandbox provisions a `runc-kvm` Pod
  instead. This is an explicit per-session decision, not the
  default — the user takes the isolation downgrade only when
  they need it.

This is a meaningful security correction; carry it through
Phase 8's migration plan.

### Bootstrap flow

The flake's responsibility ends at "the cluster is up with all
platform components installed and Flux watching the dynamic
path." Concretely:

1. NixOS provisions the cluster microvm with k3s + the
   bundled stack. Cluster API up; CoreDNS, metrics-server,
   Traefik, kube-proxy, flannel, ServiceLB, local-path-
   provisioner running. RuntimeClass YAMLs from the manifests
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
- **Service + NodePort** exposes SSH; host Caddy proxies from the
  vMGMT zone
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
headroom. With QEMU+balloon, the cluster's `mem` ceiling can be set
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

### Phase 1 — Stand up the cluster microvm with platform fully declared

Everything platform-level is declared in the flake; no manual
imperative steps. The k3s pivot makes this phase substantially
shorter than earlier revisions implied.

**Microvm guest setup:**

- Build the microvm guest on calvard. Trails-themed name.
  cloud-hypervisor backend (matches existing pattern); validate
  virtio-balloon support during this phase. `mem` ceiling
  16 GB initial, 4 vCPU.
- One virtio-net interface to a new `cluster` zone.
- gVisor's `runsc` binary in the cluster microvm OS
  (`pkgs.gvisor` if available; otherwise prebuilt from
  upstream).
- iSCSI client tools (`pkgs.openiscsi`) in the cluster microvm.
- containerd shim configuration registering `runsc` (k3s'
  containerd template extension).

**NixOS declares:**

- `services.k3s.enable = true` with default settings — flannel,
  Traefik, ServiceLB, CoreDNS, metrics-server, kine+SQLite,
  kube-router NetworkPolicy all bundled and enabled.
- HelmChart resources (via k3s' `manifests/` auto-apply
  directory):
  - `external-snapshotter` (must apply before democratic-csi —
    provides VolumeSnapshot CRDs)
  - `cert-manager` + step-ca ClusterIssuer (must apply before
    anything that requests a Certificate)
  - `democratic-csi` (zfs-generic-iscsi driver targeting
    liberl)
  - `kyverno` with ClusterPolicies scoped explicitly to the
    `woodpecker-builds` namespace (do NOT enforce image source
    cluster-wide — would block bootstrap of platform
    components)
  - `flux` configured to bootstrap against the
    dynamic-manifest path in this flake
- RuntimeClass YAMLs (`runc` default, `runsc` for sandboxed,
  `runc-kvm` for /dev/kvm-needing) in the manifests directory.

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

**Apply:** `nixos-rebuild switch`.

**Validation:**

- `kubectl get pods -A` — k3s system Pods (CoreDNS, Traefik,
  metrics-server, ServiceLB, local-path-provisioner) plus
  cert-manager, external-snapshotter, democratic-csi, Kyverno,
  Flux all `Running`
- `kubectl get runtimeclass` — runc, runsc, runc-kvm present
- Test pod with `runtimeClassName: runsc` runs and is
  sandboxed (`cat /proc/version` shows gVisor kernel string,
  not the cluster microvm's)
- Test PVC against democratic-csi: provisions on liberl,
  binds, snapshots successfully via VolumeSnapshot
- Test Certificate request: cert-manager issues from step-ca,
  binds to a Secret
- Pod-to-pod, pod-to-host-deny-default, pod-to-internet-only-
  via-router6-allows behave as expected
- balloon behavior: cluster microvm `mem` actual usage tracks
  workload; pressure-test by spinning up several pods and
  watching host-side memory accounting
- Hostile-test from Appendix A's checklist runs cleanly under
  `runsc`

**Phase 1 is complete when**: the cluster comes up cleanly
from a fresh `nixos-rebuild switch`, all the above validations
pass, and Flux is reconciling an (initially placeholder)
dynamic-manifest path.

### Phase 2 — First workload: the blog

- Deployment + Service + Flux reconciler watching the content repo
  for image updates.
- Caddy on the host forwards `blog.*` to the NodePort.
- Exercises the whole stack with the lowest-stakes workload.

### Phase 3 — Game server with CSI snapshot

- Pick the smallest game in the planned set (probably Minecraft).
- Use democratic-csi for the world volume.
- Validate suspend/snapshot/resume. This is the prototype that
  was originally going to live as the deployd iSCSI add-on.

### Phase 4 — CI runners

- Deploy a runner controller (ARC equivalent for Forgejo Actions).
- Pull the runner setup that was planned for saint-arkh into the
  cluster.
- Decommission saint-arkh's planned role; the microVM allocation
  can be reclaimed or repurposed.

### Phase 5 — Migrate edith into the cluster

Earliest start: ~6 months into cluster operation, after Phases 2–4
have run reliably.

- Build a NixOS-as-Pod base image for edith via
  `dockerTools.streamLayeredImage`.
- Define a StatefulSet with PVCs for `/nix`, `/home`,
  `/etc/nixos`, and other state directories.
- Run the new edith-pod in parallel with the existing Incus edith
  for a few weeks. Validate that builds, dev workflows, sshd
  access, and Caddy routing all work.
- Cut over by switching DNS / Caddy routes to the new edith.
- Keep the Incus edith declared (but stopped) for several more
  weeks as a rollback option. Once confidence is high, remove the
  Incus declaration.

### Phase 6 — Migrate trista similarly

After edith has run reliably in the cluster.

### Phase 7 — Decommission Incus

- Once both dev envs are in the cluster, remove `common.incus`
  from calvard and erebonia.
- Reclaim the storage pool space.
- The flake gains one less control-plane module.

### Phase 8 — Migrate cc-sandbox from deployd to k8s

After the cluster has been operating reliably for 12+ months.

- Reimplement the OIDC-authenticated Pod-creation flow as a small
  k8s controller (or extend deployd-api to talk to the k8s API
  instead of the helper).
- Validate that nested-KVM works in a runc Pod with the
  kvm-device-plugin and a `RuntimeClass: runc-kvm` definition.
- Cut over cc-sandbox's CLI to the new endpoint.

### Phase 9 — Decommission deployd

- Remove `modules/deployd/` and `packages/deployd-{api,helper}`
  from the flake.
- Reclaim erebonia's deployd microvm guest (`roer`).

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

### Talos as the cluster microvm's OS (instead of NixOS+k3s)

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
why it's the right answer for our microvm-confined cluster.

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
  - to: [{ ipBlock: { cidr: <ardent-ipv4>/32 } }]     # attic cache
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
creil / ardent first; CI fetches from those. This gives a
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

router6's `cluster` zone gates the cluster microvm's egress to
creil / ardent / phantasma; NetworkPolicy gates per-pod egress
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
  between bastion and the cluster microvm. Bastion runs trusted
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
  external 22 → cluster microvm's NodePort.
- **router6** allows inbound `<external>:22` → cluster microvm
  only via that path.
- **NetworkPolicy ingress** restricts which sources can reach the
  bastion pod's port 22 — at minimum, only the cluster microvm's
  interface.

If bastion access is **tailnet-only** (recommended), the inbound
surface shrinks dramatically: no public internet exposure, only
headscale/tailscale-attached clients. router6's `cluster` zone
gets `inputRules` allowing port 22 only from the tailnet zone.

#### Egress is much broader than CI

CI's egress is narrow (creil, ardent, phantasma). Bastion needs:

- DNS (phantasma:53)
- SSH (port 22) to **most internal hosts** — the bastion's job is
  to be the jump-off point
- step-ca:443 if SSH certs are validated against it
- Authelia/Keycloak:443 for OIDC SSH auth (if used)

This is genuinely a bigger attack surface than CI: a compromised
bastion has more places to pivot to. Mitigation: limit which
**target hosts** the bastion can SSH to with explicit destination
IPs in NetworkPolicy + router6 forwardRules — not "all of vMGMT"
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
    # `from:` empty/restricted to cluster microvm interface only

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
vMGMT/vDMZ/vINFRA on port 22, plus `inputRules` allowing inbound
22 from the tailnet zone → microvm:nodeport.

### Should the bastion actually go in k8s?

The bastion is **borderline** for k8s. It is:

- Long-lived (not the ephemeral case k8s shines at)
- Stateful (PVC-required for persistent homes)
- Network-policy-heavy (broad egress, careful ingress)
- Foundational (compromise = homelab pivot)

A microvm.nix guest with `services.openssh.*` and
`services.step-ssh.*` is a perfectly clean alternative — it
would live in vDMZ alongside langport. The same per-service-
failure-domain reasoning that keeps Authelia / step-ca on
microvm.nix applies here.

#### The k8s case for bastion

- Cluster is already running (Path B says yes for Phases 2–4).
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

This is one place where the consolidation goal of Path B should
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

### Stage 0 — Single-node (Phases 1–4)

One cluster microvm on calvard. All workloads scheduled there.

- Simplest. One microvm to maintain, one NixOS module set, one
  router6 firewall config.
- No HA. Cluster down ≡ calvard's cluster microvm down.
- Sufficient for the initial workload set (blog, one game
  server, modest CI burst).

This is where the migration plan starts. Don't pay multi-node
costs before there's a workload reason.

### Stage 1 — Multi-node (Phase 10)

Add erebonia as a worker node. Single control plane on calvard;
erebonia is a worker only.

#### How it maps onto host roles

The homelab's existing host structure aligns naturally:

- **calvard** (primary VM host): control plane + interactive
  workloads (blog, dev environments when migrated, small
  services)
- **erebonia** (build/CI host): worker node for batch workloads
  (CI build pods, game servers where compute-heavy)

Erebonia is *already* the build/CI host — having it host CI
worker capacity (instead of a saint-arkh microvm running a
Forgejo runner daemon) is a more natural extension of its role.
Once deployd sunsets in Phase 9, erebonia would otherwise be
underutilized; cluster worker is a clean job for it.

Workload pinning via labels and taints:

```yaml
# CI step pods
spec:
  nodeSelector:
    workload-class: batch        # erebonia
  tolerations:
  - key: ci-only
    operator: Exists

# dev environment pods
spec:
  nodeSelector:
    workload-class: interactive  # calvard
```

#### What this is and isn't

- **Workload distribution**, yes. Burst capacity for CI lands on
  erebonia; calvard stays responsive for interactive work.
- **HA**, no. Single control plane on calvard is still SPOF for
  the API. Existing pods on erebonia keep running if calvard
  dies (kubelet caches its assigned pod set), but no new
  scheduling. Don't pretend otherwise.

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

- More cluster surface (two cluster microvms, two firewall
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
# liberl's node spec (set by kubeadm init/join, doesn't need manual config)
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

- One more cluster microvm to maintain (3 instead of 2).
- liberl gains a cluster role on top of NAS. If liberl reboots
  for NAS maintenance (NixOS upgrade), the cluster loses one
  control-plane vote temporarily. Still has 2/3 quorum, fine —
  but it's a new dependency to think about.
- Bootstrap order matters. First node initializes
  (`kubeadm init` or k0s equivalent), other two join
  (`kubeadm join --control-plane`). Document this in the
  runbook.

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

- CI burst capacity on calvard's cluster microvm hits its
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
  the k8s control plane). Overkill at homelab scale. Embedded
  etcd via kubeadm/k0s is what you want.
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
  2. **NixOS-decrypts-at-boot, mounts into cluster microvm.**
     The cluster microvm's NixOS layer uses sops-nix to
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
  Cilium (see Risks). With the v15 default of flannel + kube-
  router, Hubble isn't available; debugging falls back to
  `iptables -L` inside the cluster microvm and router6 audit
  logs on the host. Acceptable for v1; revisit if
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
- **Forgejo Actions**: actions-runner-controller pattern (or
  Forgejo equivalent) for autoscaled per-job gVisor-sandboxed
  pods (Appendix A). Webhook-driven workflows via Argo Events
  for more complex pipelines.
- **Headscale (planned altair)**: there's a community
  headscale-operator for auto-registering cluster services as
  tailnet nodes. Niche but interesting if you want cluster
  workloads to appear directly on the tailnet.
- **NAS (liberl)**: democratic-csi for PVCs (already covered).
  VolumeSnapshot for declarative backup of stateful workloads.
- **Hubble (Cilium)**: flow observability across cluster
  workloads. Pairs with router6's audit logging at the host
  level for end-to-end network visibility.

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
- **Push-to-deploy CI/CD.** Forgejo Actions builds an image,
  pushes to creil, updates a manifest in `cluster/manifests/`
  via git push, Flux picks it up, rolls out the new image.
  End-to-end automation without per-workload deploy scripts.

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
  workloads under runc share the cluster microvm's kernel;
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

## Revision history

- v1: initial pass — recommended staying, ~90/10. Anchored too hard
  on the prior k3s rejection and treated the kata-cgroup decision
  as authoritative for the orchestration question (it isn't).
- v2: fresh-eyes rewrite — recommended staying, 60/40. Conceded
  k8s ≠ k3s, kubelet+containerd+kata is better-supported, operator
  ecosystem fit is real for CI runners and CSI.
- v3: added dual-firewall composition section. Showed that
  "router6 authoritative, CNI additive only" is achievable in a
  shared kernel with discipline, at the cost of ~1.5x debug
  surface.
- v4: added mechanical-prevention section comparing rootless k8s
  to k0s-in-a-microvm. Microvm-confined deployment provides the
  same mechanical isolation as rootless without the rootless
  workload-breaking penalties.
- v5: integrated findings into a coherent recommendation. The
  microvm framing changed the recommendation from "stay" to
  "build new dynamic work on a cluster, leave existing things
  alone."
- v15 (this revision): incorporated independent review
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
