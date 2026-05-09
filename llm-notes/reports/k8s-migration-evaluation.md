# Kubernetes Migration Evaluation

Date: 2026-05-09 (v6 — see revision history at end)

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
| CI runners (saint-arkh deferred) | — | k8s | Runner controller + per-job kata pods |
| Claude sandboxes | deployd | k8s eventually | Stay on deployd until cluster proven; migrate as part of deployd sunset |
| Dev environments (edith, trista) | Incus | k8s | StatefulSet + PVC; migrate one at a time after cluster proves out |
| Authelia and other small foundational services | microvm.nix | microvm.nix | Per-service failure domain still wins for foundational state |
| Static fleet (Forgejo, Jellyfin, Prometheus, etc.) | microvm.nix | microvm.nix | Don't migrate what works |

### Why this answer

The full chain of reasoning that produced it (across revisions of
this report):

- **k8s ≠ k3s.** The earlier rejection of k3s in
  `llm-notes/specs/dynamic-container-layer.md:47` was about k3s's
  bundled defaults (Traefik, ServiceLB, flannel) conflicting with
  declared NixOS choices, not about k8s broadly. A
  `services.kubernetes.*` or k0s deployment is meaningfully
  different.
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

## Architecture

### Run the cluster inside a microvm guest

The cluster's control plane and kubelet run inside a single
microvm.nix guest, the same way `roer` runs deployd-api today.
Pods are processes inside that guest's kernel. The host sees one
VM with one virtio-net interface and some virtio-blk traffic.

For Kata pods, the kata shim spawns cloud-hypervisor *inside* the
microvm, creating a nested KVM VM per kata pod. This works because
the microvm has KVM available — `erebonia` already enables nested
virtualization (`kvm_intel nested=1`) and the cluster microvm needs
the same.

### Hypervisor backend: QEMU, not cloud-hypervisor

microvm.nix supports multiple hypervisor backends. The existing
guests use cloud-hypervisor by default (fast boot, minimal idle
overhead). For the cluster guest specifically, **QEMU is the right
choice**:

- **Mature virtio-balloon support.** QEMU dynamically pools memory
  between guests as workloads breathe. The cluster idles at
  ~2–4 GB and balloons up to its max only when CI runners or game
  servers are active. cloud-hypervisor's balloon support is less
  mature and would need additional work.
- **Boot-speed cost is irrelevant for a long-running guest.** The
  ~5s vs. ~200ms boot difference matters for ephemeral guests,
  not for a cluster that lives for months.
- **~50–100 MB more idle overhead** is small relative to the
  cluster's working set.

A few existing guests (`saint-arkh`, `ardent`, `monrain`) already
use QEMU; this isn't a new pattern in the repo.

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
| Nested KVM (kata pods, NixOS-test sandboxes) | additional 10–20% CPU |

For the named workloads:

- Blog: invisible.
- CI runners: builds 5–10% slower than bare-metal — fine for a
  homelab.
- Claude sandboxes: 5–15% slower than bare-metal runc once
  migrated.
- Game servers: ~5% network, ~3% CPU. Imperceptible to players.
- Dev environments: identical to today (edith already runs as an
  Incus container with similar overhead).

Dramatically better than rootless k8s and similar to running any
other microvm guest.

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

## Component picks

- **Distribution**: `services.kubernetes.*` (most NixOS-native;
  control plane declared in the same flake) or k0s (single binary,
  simpler bootstrap, available in nixpkgs). **Not k3s** — its
  bundled defaults conflict with the homelab's existing decisions.
- **Hypervisor backend (microvm.nix)**: QEMU with virtio-balloon,
  not cloud-hypervisor. See "Hypervisor backend" above.
- **CNI**: Cilium with `kubeProxyReplacement=true`,
  `hostFirewall=false`, `bpf.masquerade=true`, VXLAN tunneling.
  Calico in policy-only mode is a simpler alternative if Cilium's
  eBPF requirements prove problematic in the nested setup.
- **CSI**: democratic-csi against the NAS (zfs-generic-iscsi or
  zfs-generic-nfs). Provides VolumeSnapshot for game servers and
  dev environments.
- **Ingress**: keep host Caddy. Cluster exposes services as
  `ClusterIP` + `NodePort`; Caddy on the host forwards from
  tailscale0/dmz to the cluster's NodePort range. SSH ingress to
  dev-environment Pods is via the same path.
- **GitOps**: Flux v2 reading manifests from creil. Manifests live
  in this flake.
- **RuntimeClasses**:
  - `kata-qemu` — default for new isolated workloads
  - `runc` — general-purpose, dev environments
  - `runc-kvm` — runc + kvm-device-plugin for nested-KVM workloads

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

### Phase 1 — Stand up the cluster microvm

- Build the microvm guest on calvard. Probably named per the
  existing Trails theme. QEMU backend, virtio-balloon, `mem`
  ceiling 16 GB (initial), 4 vCPU.
- One virtio-net interface to a new `cluster` zone in router6.
- Distribution: `services.kubernetes.*` or k0s.
- Define the `cluster` zone with explicit egress allows for image
  pull (creil:443), DNS (phantasma:53), and internet:443. Caddy on
  the host gets a NodePort proxy block for inbound.
- Install Cilium with the configuration above. Verify pod-to-pod,
  pod-to-host (deny by default), pod-to-internet (only via router6
  allows).
- Install Flux pointed at a new repo path in this flake (e.g.,
  `cluster/manifests/`).

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

- **Cilium nested-KVM oddities.** eBPF programs in a nested
  virtualization environment can be sensitive to host kernel
  versions. Validate the eBPF datapath functionality in Phase 1
  before committing workloads. Fallback: Calico in policy-only
  mode is less performant but doesn't depend on advanced eBPF
  features.
- **Kata-in-microvm performance.** Three KVM levels (host →
  microvm → kata pod). Acceptable for most workloads; for
  CPU-intensive sandboxes might warrant `runc` with restricted
  capabilities instead of `kata-qemu`.
- **CSI iSCSI from inside a microvm.** The microvm needs to be the
  iSCSI initiator, or get LUNs passed through as virtio-blk.
  Validate the snapshot/restore cycle on the prototype game-server
  workload before betting on it for dev environments.
- **Dev-env migration risk.** edith is the operator's daily
  driver. Mitigation: parallel-run during cutover, keep trista
  on Incus until edith is proven, leave the Incus declaration
  live for several weeks of rollback window.
- **Operator skill investment.** k8s is a real learning curve.
  The operator-facing UX for dev environments specifically
  (`kubectl exec` vs. `incus console`) is less polished. If after
  Phase 4 the operator's preference is clearly to extend
  deployd / keep Incus rather than learn more k8s, the
  recommendation should be re-evaluated — Phase 5 onward isn't
  forced.

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
- v6 (this revision): committed to **Path B** — phased migration
  of dev environments (edith, trista) into the cluster, with
  Incus eventually decommissioned. Switched the cluster guest's
  hypervisor backend to QEMU for memory ballooning (the
  motivating concern). Made the rollback-via-NixOS framing
  explicit at each migration phase. Endgame is three control
  planes (NixOS + microvm.nix + k8s) instead of four. Re-examined
  the previous "k8s is for cattle, not pets" framing — Pods +
  PVCs + `RuntimeClass: runc` is a mature pattern for dev
  environments, used by Coder/Gitpod/Codespaces.
