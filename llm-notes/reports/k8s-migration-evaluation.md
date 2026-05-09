# Kubernetes Migration Evaluation

Date: 2026-05-09 (v5 — see revision history at end)

## Question

Should we replace the dynamic-container layer (`deployd`,
single-host on erebonia) with a Kubernetes-based runtime? If yes,
what shape should the deployment take? Could it replace any static
microvm guests?

## Recommendation

**Stand up a Kubernetes cluster inside a microvm guest. Build new
dynamic workloads on it. Leave existing deployd workloads (cc-sandbox)
where they are. Leave the static fleet on microvm.nix. Let the cluster
grow into freed resources as workloads land — don't pre-commit
headroom.**

This is meaningfully different from the original "don't migrate"
framing. The change came from realizing that running the cluster as
a microvm guest — the same way every other isolated service is
deployed in this homelab — removes the largest operational concerns
about adopting k8s.

### What goes where

| Workload | Home | Notes |
| --- | --- | --- |
| Blog (planned) | k8s | Canonical Deployment + Flux pattern; smallest first workload |
| Game servers (planned) | k8s | CSI snapshots replace the custom iSCSI add-on |
| CI runners (saint-arkh deferred) | k8s | Runner controller + per-job kata pods |
| Claude sandboxes | deployd | Works; security model hand-tuned; revisit later |
| Authelia and other foundational services | microvm.nix | Per-service failure domain still wins |
| Future small auxiliary services | microvm.nix today, k8s once cluster matures | Crossover decision per service |
| Static fleet (Keycloak→Authelia, Forgejo, Jellyfin, Prometheus, etc.) | microvm.nix | Don't migrate what works |

### Why this answer rather than "migrate everything" or "stay on deployd"

- **"Migrate everything" isn't right** because the static fleet works,
  the per-service migration cost is real, and no static workload has a
  k8s-specific reason to move strong enough to justify it.
- **"Stay on deployd" was the previous recommendation.** It
  under-weighted three things the iterative analysis surfaced:
  - **k8s ≠ k3s.** The earlier rejection of k3s in
    `llm-notes/specs/dynamic-container-layer.md:47` was about k3s's
    bundled defaults (Traefik, ServiceLB, flannel) conflicting with
    declared NixOS choices, not about k8s broadly. A
    `services.kubernetes.*` or k0s deployment is meaningfully
    different.
  - **kubelet+containerd+kata is the better-supported integration
    path** for kata than nerdctl+containerd+kata. Most of the
    integration friction we've been hitting (CNI ID prefixes,
    rootful/rootless confusion, ctr-inspect parsing) lives in
    nerdctl as a Docker-compat wrapper, not in containerd or kata.
  - **Operator ecosystem fit is real** for CI runners (autoscaling
    runner controllers like ARC) and game servers (CSI
    VolumeSnapshot vs. building our own iSCSI add-on).
- **The microvm-confined deployment** makes the migration
  **reversible** (turn off the guest if it doesn't work) and
  **contained** (host firewall, host kernel, and the rest of the
  homelab are mechanically isolated from the cluster).

## Architecture

### Run the cluster inside a microvm guest

The cluster's control plane and kubelet run inside a single
microvm.nix guest, the same way `roer` runs deployd-api today.
Pods are processes inside that guest's kernel. The host sees one
VM with one virtio-net interface and some virtio-blk traffic.

For Kata pods, the kata shim spawns cloud-hypervisor *inside* the
microvm, creating a nested KVM VM per kata pod. This works because
the microvm has KVM available — `erebonia` already enables nested
virtualization (`kvm_intel nested=1`).

### Why microvm-confined rather than on-host

Running the cluster in a guest VM:

- **Mechanically prevents the cluster from touching router6.** The
  microvm has its own kernel and its own `nf_tables`. The host's
  `nf_tables` is unreachable across the hypervisor boundary — not
  a syscall question, a hardware question. No CNI can install
  rules that affect router6 because there's no path. Stronger than
  rootless k8s (which has user-namespace edge cases) and stronger
  than convention.
- **Lets the CNI work normally.** Cilium with eBPF, full feature
  set, because inside the microvm kubelet *is* root. Avoids the
  20–50% network penalty of rootless slirp4netns/pasta, the broken
  CSI iSCSI story, and the unproven kata-rootless path.
- **Reduces the dual-firewall debug surface** to "one firewall per
  kernel, debugged in that kernel's tooling."
- **Reversible.** A failed cluster is one microvm to destroy. The
  static fleet, deployd, and the host are unaffected.
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
| Nested KVM (kata pods, NixOS-test sandboxes) | additional 10–20% CPU |

For the named workloads:

- Blog: invisible.
- CI runners: builds 5–10% slower than bare-metal. Fine for a
  homelab.
- Claude sandboxes: 5–15% slower than today's bare-metal runc.
  (Academic in the recommended plan — cc-sandbox stays on deployd.)
- Game servers: ~5% network, ~3% CPU. Imperceptible to players.

Dramatically better than rootless (20–50% network penalty) and
similar to running any other microvm guest.

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
  microvm boundary. It's not visible to the cluster.
- The cluster's CNI manages pod-to-pod and pod-to-microvm-edge
  policy. Pod traffic exiting the microvm masquerades to the
  microvm's IP (Cilium `bpf.masquerade=true`); router6 enforces
  what that microvm IP is allowed to do.

So the dual-firewall complication discussed in earlier revisions
collapses. Each firewall is reasoned about with its own kernel's
tooling. There's no priority ordering to worry about, no
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
  in NetworkPolicy. This is the right layering — coarse zone
  policy at router6, fine-grained per-pod policy in the cluster.
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

## Component picks

- **Distribution**: `services.kubernetes.*` (most NixOS-native;
  control plane declared in the same flake) or k0s (single binary,
  simpler bootstrap, available in nixpkgs). **Not k3s** — its
  bundled defaults conflict with the homelab's existing decisions
  and would need to be disabled.
- **CNI**: Cilium with `kubeProxyReplacement=true`,
  `hostFirewall=false`, `bpf.masquerade=true`, VXLAN tunneling.
  Full eBPF datapath, NetworkPolicy enforcement, no kube-proxy.
  Calico in policy-only mode is a simpler alternative if Cilium's
  eBPF requirements (kernel features, unprivileged BPF) prove
  problematic in the nested setup.
- **CSI**: democratic-csi against the NAS (zfs-generic-iscsi or
  zfs-generic-nfs). Provides VolumeSnapshot for game servers.
- **Ingress**: keep host Caddy. Cluster exposes services as
  `ClusterIP` + `NodePort`; Caddy on the host forwards from
  tailscale0/dmz to the cluster's NodePort range.
- **GitOps**: Flux v2 reading manifests from creil. Manifests live
  in this flake.
- **RuntimeClasses**:
  - `kata-qemu` — default for new isolated workloads
  - `runc` — general-purpose
  - `runc-kvm` — runc + kvm-device-plugin for nested-KVM workloads

## Static fleet and the shrinking-services dynamic

The static fleet is migrating to lighter equivalents (Keycloak →
Authelia, etc.). Plausibly 6–10 GB RAM and 100+ GB disk freed over
the next year.

**Should the freed resources go to the cluster?** Mostly no.
Cluster sizing should be driven by workloads, not by available
headroom. Start at 4 GB / 2 vCPU; grow to 8–16 GB / 4 vCPU as
workloads land. The remainder stays as host slack — useful for all
guests, not just the cluster.

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

The shrinking-services trend marginally favors k8s but isn't a
tipping point. The bigger driver is whether new dynamic workloads
land — which they will (blog, game servers, CI runners), which
justifies standing up a cluster regardless.

## What about KubeVirt?

KubeVirt would let static services run as `VirtualMachine` resources
inside the cluster, getting CSI snapshots and a unified API. Worth
knowing about for completeness, not justified here:

- Adds significant complexity (operators, CRDs, virt-handler
  daemonsets) for a homelab.
- microvm.nix is much lighter than KubeVirt VMs at this scale.
- Loses NixOS-native module declarations like
  `services.authelia-main.enable = true`.
- Worth revisiting only if the cluster matures into a primary-
  platform position over years.

## Migration plan

Land work in roughly this order:

1. **Build the cluster microvm guest.** Probably on calvard.
   4 GB RAM, 2 vCPU initially. One virtio-net interface to a new
   `cluster` zone. Distribution: `services.kubernetes.*` or k0s.
2. **Wire the network.** Define the `cluster` zone in router6 with
   explicit egress allows for image pull (creil:443), DNS
   (phantasma:53), and internet:443. Caddy on the host gets a
   NodePort proxy block for inbound.
3. **Install Cilium** with the configuration above. Verify
   pod-to-pod, pod-to-host (deny by default), pod-to-internet (only
   via router6 allows).
4. **Install Flux** pointed at a new repo path in this flake (e.g.,
   `cluster/manifests/`).
5. **First workload: the blog.** Deployment + Service + Flux
   reconciler watching the content repo for image updates. Caddy
   forwards `blog.*` to the NodePort. Exercises the whole stack.
6. **Second workload: a game server with CSI snapshot.** Pick the
   smallest game in the planned set (probably Minecraft). Use
   democratic-csi for the world volume. Validate the
   suspend/snapshot/resume workflow before committing to multi-game.
7. **Third workload: CI runners.** Deploy a runner controller; pull
   the Forgejo Actions runner setup that was planned for saint-arkh
   into the cluster. Decommission saint-arkh's planned role if this
   works.
8. **Sunset criterion for deployd.** Documented up front: if the
   cluster runs at least one production workload reliably for 12
   months, evaluate migrating cc-sandbox. If issues arise that make
   the cluster impractical, turn off the microvm and continue
   extending deployd. The decision point is explicit.

## Risks and what could change the recommendation

- **Cilium nested-KVM oddities.** eBPF programs in a nested
  virtualization environment can be sensitive to host kernel
  versions. Validate the eBPF datapath functionality early.
  Fallback: Calico in policy-only mode is less performant but
  doesn't depend on advanced eBPF features.
- **Kata-in-microvm performance.** Three KVM levels (host →
  microvm → kata pod). Acceptable for most workloads; for
  CPU-intensive sandboxes might warrant `runc` with restricted
  capabilities instead of `kata-qemu`.
- **CSI iSCSI from inside a microvm.** The microvm needs to be the
  iSCSI initiator, or get LUNs passed through as virtio-blk.
  Validate the snapshot/restore cycle on the prototype game-server
  workload before betting on it.
- **Operator skill investment.** k8s is a real learning curve. If
  the operator's preference is to extend deployd's small Rust
  codebase rather than learn kubelet/CNI/CSI/admission, the
  recommendation flips back to "stay." This is a personal
  preference question, not a technical one.

## Revision history

- v1: initial pass — recommended staying, ~90/10. Anchored too hard
  on the prior k3s rejection and treated the kata-cgroup decision
  as authoritative for the orchestration question (it isn't).
- v2: fresh-eyes rewrite — recommended staying, 60/40. Conceded
  k8s ≠ k3s, kubelet+containerd+kata is better-supported, operator
  ecosystem fit is real for CI runners and CSI.
- v3: added dual-firewall composition section. Showed that
  "router6 authoritative, CNI additive only" is achievable in a
  shared kernel with discipline (no LoadBalancer/MetalLB, Cilium
  with `hostFirewall=false`), at the cost of ~1.5x debug surface.
- v4: added mechanical-prevention section comparing rootless k8s to
  k0s-in-a-microvm. Microvm-confined deployment provides the same
  mechanical isolation property as rootless without the rootless
  workload-breaking penalties (network performance, broken CSI
  iSCSI, unproven kata-rootless).
- v5 (this revision): integrated findings into a coherent
  recommendation. The microvm framing changed the recommendation
  from "stay" to "build new dynamic work on a cluster, leave
  existing things alone." Added performance characterization,
  community-pattern context, the shrinking-services dynamic, and
  a concrete migration plan with a sunset criterion for deployd.
