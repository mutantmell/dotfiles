# Kubernetes Migration Evaluation

Date: 2026-05-09 (v9 — see revision history at end)

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

#### 2. Kata as RuntimeClass — the actual security boundary

```yaml
spec:
  runtimeClassName: kata-qemu
```

Each step pod becomes a real KVM VM with its own kernel.
Container-escape vulnerabilities escape into the kata VM, which
has no host privileges and no path back to the cluster. The kata
VM is destroyed at end-of-step.

In our microvm-confined cluster setup this means three KVM
levels: host → cluster microvm → per-step kata VM. ~10–20% CPU
overhead vs. runc; CI builds run measurably slower but not
crippled. For untrusted-code execution this is the correct
trade.

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
  - to: [{ ipBlock: { cidr: 10.97.100.53/32 } }]   # creil — git + registry
    ports: [{ protocol: TCP, port: 443 }]
  - to: [{ ipBlock: { cidr: 10.97.11.2/32 } }]     # phantasma — DNS
    ports: [{ protocol: UDP, port: 53 }]
  - to: [{ ipBlock: { cidr: 10.97.100.31/32 } }]   # ardent — attic cache
    ports: [{ protocol: TCP, port: 443 }]
```

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

- `runtimeClassName` MUST be `kata-qemu` in
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
  - All step pods: runtimeClassName=kata-qemu
  - Default-deny NetworkPolicy + explicit egress allows
  - Kyverno policies enforcing image source and runtimeClass
  - ResourceQuota capping total concurrent build CPU/memory
```

router6's `cluster` zone gates the cluster microvm's egress to
creil / ardent / phantasma; NetworkPolicy gates per-pod egress
within those bounds.

### Comparison: saint-arkh planned vs. k8s + kata

| Property | saint-arkh (planned) | k8s + kata |
| --- | --- | --- |
| Runner-to-host isolation | microVM (KVM boundary) | microVM **plus** per-step kata VM |
| Step-to-step isolation | none — same runner host | each step is a fresh kata VM |
| Network policy granularity | host-level only | per-pod NetworkPolicy + host zone |
| Image source enforcement | manual | admission controller |
| Resource accounting | per-runner | per-step |
| Recovery on compromise | rebuild the whole VM | tear down one step pod |

The microVM still exists (the cluster's microvm), but it's
shared infrastructure. Each individual build is isolated to
its own kata VM inside it.

This replaces saint-arkh's planned role. The saint-arkh
allocation can be reclaimed once the cluster's CI workflow is
operational (Phase 4 of the migration plan).

### What this stack is NOT

The defense-in-depth here is correct for the realistic threat
model (untrusted build code, hostile dependencies, compromised
PRs). It is not a complete security architecture against:

- **Higher threat profiles** (nation-state APTs) would warrant
  additional layers: gVisor as a second-stage sandbox,
  mandatory image signing via cosign + admission policy,
  per-pipeline ephemeral credentials via Vault, more
  aggressive egress monitoring.
- **Misconfiguration**. Each layer is independently
  configurable and independently verifiable. Audit each layer;
  don't assume "we're using k8s" implies "we're secure." A
  step pod without `runtimeClassName: kata-qemu` is just a
  runc pod — no isolation. Admission policies must enforce
  this.
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

- [ ] `kubectl get runtimeclass kata-qemu` returns a valid
  RuntimeClass
- [ ] PSS labels on the namespace enforce `restricted`
- [ ] Kyverno (or equivalent) policies are loaded and tested:
  reject a pod without `runtimeClassName: kata-qemu` in the
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

- **`runtimeClassName: kata-qemu`** — same reason, kernel-level
  isolation between bastion and the cluster microvm.
- **PSS Restricted profile** on the namespace — drops
  capabilities, blocks host namespaces, forces non-root.
- **Admission policies** (Kyverno/OPA) enforcing image source =
  creil and `runtimeClassName: kata-qemu`.
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
      runtimeClassName: kata-qemu
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
  - to: [{ ipBlock: { cidr: 10.97.11.2/32 } }]    # phantasma DNS
    ports: [{ protocol: UDP, port: 53 }]
  - to: [{ ipBlock: { cidr: 10.97.11.7/32 } }]    # basel — SSH cert validation
    ports: [{ protocol: TCP, port: 443 }]
  - to: [{ ipBlock: { cidr: 10.97.11.6/32 } }]    # messeldam — OIDC
    ports: [{ protocol: TCP, port: 443 }]
  # SSH targets — explicit allowlist
  - to:
    - { ipBlock: { cidr: 10.97.20.0/24 } }        # vMGMT
    - { ipBlock: { cidr: 10.97.100.0/24 } }       # vDMZ
    - { ipBlock: { cidr: 10.97.11.0/24 } }        # vINFRA
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
- v9 (this revision): added Appendix C — cluster topology
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
