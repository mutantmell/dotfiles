# Kubernetes Migration Evaluation

Date: 2026-05-09 (revised — fresh-eyes pass)

## Question

Would moving the dynamic-container layer (today: `deployd` +
`packages/deployd-{api,helper}/`, single-host on erebonia) to a
Kubernetes-based runtime be a net improvement?

Sub-questions:

1. Is k8s a good fit for the workload classes deployd serves (blogs,
   CI runners, Claude Code sandboxes, game servers)?
2. Which k8s distribution and runtime would best fit this homelab?
3. Could k8s replace any of the static microvm.nix / Incus guests?
4. On balance, migrate or stay?

## Approach

This pass deliberately re-derives the answer rather than leaning on the
prior decisions in `llm-notes/specs/dynamic-container-layer.md` (which
rejected **k3s specifically**, not k8s broadly) and
`llm-notes/done/kata-cloud-hypervisor-migration.md` (which is about
mutable-NixOS-in-kata, not orchestration). Those documents are evidence
of past reasoning, not authority on this question.

## What "Kubernetes" actually means here

It's important to disentangle three different things often called "k8s":

- **The k8s API** — Pod / Deployment / StatefulSet / Job / CRD,
  reconciliation loops, RBAC, audit. Distribution-agnostic.
- **kubelet + CRI + containerd** — the per-node agent that drives
  containerd (and therefore kata-shim-v2) on behalf of the API. This is
  the same path the kata-containers project tests against first.
- **The bundled distribution** — k3s, k0s, RKE2, microk8s, kubeadm. Each
  comes with default choices for ingress, load-balancer, CNI, storage
  class. **The earlier rejection of k3s was mostly about k3s's defaults**
  (Traefik vs. our declared Caddy, ServiceLB vs. our nftables, flannel
  re-managing host firewall) — not about the underlying API.

A NixOS-native k8s build via `services.kubernetes.*` (or k0s with most
defaults disabled) is a meaningfully different proposition from k3s with
its batteries included.

## Honest case FOR migration

### 1. Kata is genuinely better-supported via kubelet than via nerdctl

Most of the integration friction we've hit (nerdctl prepending a
namespace prefix to CNI container IDs; rootful/rootless confusion when
sudo'ing nerdctl; ctr-inspect parsing; CNI state file `\r\n`) is
specifically because nerdctl is a Docker-compat CLI bolted onto
containerd, not because containerd or kata are difficult. The kata
project's reference integration is **kubelet → CRI → containerd → kata
shim**. Bug fixes ship for that path first.

Caveat: the in-flight containerd-gRPC migration in
`llm-notes/wip/deployd-integration.md` also gets us off nerdctl. So this
is a "k8s gets it for free" point, not a "only k8s solves it" point.

### 2. The operator ecosystem is unusually well-matched to the named workloads

- **Blog**: Deployment + Service + Ingress, with Flux/ArgoCD watching
  the content repo for image updates. This is the canonical k8s pattern
  and noticeably less code than wiring deployd to a webhook.
- **CI runners**: actions-runner-controller (or the Forgejo equivalent)
  autoscales runner pods on queue depth, runs each job in a fresh pod
  with its own `RuntimeClass`. Strictly better than running a long-lived
  runner daemon (saint-arkh) that spawns local jobs.
- **Claude sandboxes**: still a Pod with a `RuntimeClass` and an OIDC
  flow on top. Code-volume comparable to the current deployd-api, no
  obvious win, no obvious loss.
- **Game servers**: StatefulSet + PVC + VolumeSnapshot covers the
  "weeks-long, survives reboot, snapshot the world" use case. Agones
  exists for session-allocation-style fleets but is overkill for the
  stated requirement.

### 3. CSI is a proper home for the iSCSI block-storage feature

The iSCSI suspend/resume add-on in
`llm-notes/specs/dynamic-container-layer.md` is essentially a small,
custom storage controller. With k8s + a CSI driver
(`democratic-csi` against TrueNAS, or `openebs-mayastor`,
or `longhorn`), you get dynamic provisioning, snapshot CRDs, and clone
support out of the box. Snapshots become first-class kubernetes
resources rather than a `state.json` field.

### 4. Multi-runtime via `RuntimeClass` is the cleaner expression

The per-deploy `runtime: "kata" | "runc"` field maps directly onto k8s
`RuntimeClassName`. We can also add a custom `runc-kvm`
`RuntimeClass` (paired with the kvm-device-plugin) for the cc-sandbox
nested-KVM case without special-casing it in our own code.

### 5. Multi-host and KubeVirt as a long-term direction

If the homelab ever runs dynamic workloads across erebonia *and*
calvard, k8s schedules across them natively; deployd would need a
second instance with a manual placement decision per workload.
**KubeVirt** runs full VMs as `VirtualMachine` CRDs alongside Pods —
unmodified NixOS guests, libvirt/QEMU underneath, live migration
across nodes, snapshots via CSI. This wouldn't replace microvm.nix
tomorrow, but it's a credible 5-year direction for unifying VM and
container management under one control plane.

## Honest case AGAINST migration

### 1. CNI ↔ router6 integration is real ongoing engineering

Every CNI either (a) leaves host networking alone and provides only
pod-to-pod policy, or (b) takes ownership of large pieces of host
firewall/routing. Cilium with `hostFirewall=false` and policy-only
mode, or Calico in policy-only mode, are the "leave host alone"
choices. Either is workable but introduces a second policy surface
that needs to be reasoned about alongside `modules/router6/`.

The cluster network ends up being its own zone (vDMZ-ish); router6
governs inter-VLAN traffic; CNI governs intra-cluster. That's a
clean-enough split, but it's a real architectural change and a
permanent operational complexity tax (two firewalls to debug, not one).

### 2. Two sources of truth for workload state

Today, every workload is described in either NixOS evaluation or
deployd's `state.json` (replayed by a NixOS-defined service). With k8s,
manifests live in etcd. Reasonable mitigations:

- Store manifests in this flake, apply via Flux/ArgoCD on commit (most
  Nix-friendly).
- Generate manifests from Nix expressions and apply via `kubectl
  apply -k` from a NixOS systemd service.

Either works, but the "single declarative source" property of the
current setup is genuinely lost.

### 3. Operational footprint at small scale

Even a stripped-down k8s control plane (apiserver + etcd or
kine + controller-manager + scheduler + kubelet + CNI) is
500MB–1GB resident plus daemons-to-monitor. On a single dynamic-layer
host this is a real cost. Several static microVM guests run in 256MB.
The cost gets cheaper per-workload as the workload count grows; it's
unfavorable at today's scale.

### 4. Auth and developer-tooling surface area

deployd's auth model is a single OIDC bearer token with a group claim,
checked once per request. K8s adds RBAC, ServiceAccounts, and (for
human users) `kubectl` context management on top of the same OIDC.
For machine callers (CI deploying a blog), ServiceAccount tokens are
fine. For human callers (cc-sandbox CLI today), the auth code stays
roughly the same size but talks to a much larger API.

### 5. Custom code investment is genuinely small today

deployd is ~2k LOC of Rust (helper + api combined), with the trust
boundary in one file (`packages/deployd-helper/src/validation.rs`) and
the privileged operations in one shell script
(`modules/deployd/default.nix:39`). It's small enough to read in a
sitting and audit per-change. K8s replaces this with kubelet (~500k
LOC) + CRI runtime + admission controllers + RBAC policy. Same security
properties, much larger surface.

### 6. The static-fleet migration question is unattractive

If migration is dynamic-layer-only, k8s is justified or not on its own
merits. If it's "and the static fleet too via KubeVirt," the cost
balloons and the upside is mostly "live migration we don't need" and
"unified control plane that costs us NixOS-native module declarations
like `services.keycloak.enable = true`."

## Per-workload assessment

| Workload | Current | K8s equivalent | Honest verdict |
| --- | --- | --- | --- |
| Blog (on-demand redeploy) | not built yet | Deployment + Flux watching content repo | k8s wins on idiom |
| CI runners (Forgejo Actions) | saint-arkh microVM hosts daemon; jobs are isolated | runner controller + per-job kata Pods | k8s wins, especially at scale |
| Claude sandboxes | cc-sandbox CLI → deployd-api → runc Pod with /dev/kvm | OIDC client → k8s API → Pod with `RuntimeClass=runc-kvm` + kvm-device-plugin | roughly equivalent |
| Game servers (long-lived, weekly play) | spec'd but unbuilt; iSCSI + suspend/resume | StatefulSet + PVC + VolumeSnapshot | k8s wins on storage primitives |

So: of the four named workload classes, **two are genuinely better
served by k8s + ecosystem (CI runners, game-server storage), one is
roughly a wash (Claude sandboxes), one isn't built yet either way (blog,
where k8s is more idiomatic but neither is hard)**.

## If migrating, what runtime?

The right answer is **not k3s** — its bundled defaults (Traefik+ServiceLB
+flannel+local-path) are exactly the layers we'd disable, leaving us
fighting opinionated removals. Better:

- **`services.kubernetes.*` (kubeadm-style, NixOS module)** — most
  NixOS-native; the control plane is declared in the same flake as
  everything else. Heaviest operationally but most consistent with the
  rest of the stack.
- **k0s** — single binary, sane minimal defaults, available as a
  package in nixpkgs. Reasonable second choice.

Component picks for either:

- **CNI: Cilium** with `kubeProxyReplacement=true`,
  `hostFirewall=false`, eBPF datapath. Plays well with existing
  host nftables and gives us NetworkPolicy as the pod-policy surface.
  Calico in policy-only mode is a simpler alternative.
- **Container runtime: containerd** (only realistic choice with kata).
- **Runtimes**:
  - `RuntimeClass: kata-qemu` — default for new isolated workloads
  - `RuntimeClass: runc` — for general-purpose
  - `RuntimeClass: runc-kvm` — runc with kvm-device-plugin for
    cc-sandbox-style nested-KVM
- **CSI: democratic-csi** against the NAS (zfs-generic-iscsi or
  zfs-generic-nfs depending on workload). Gives us VolumeSnapshot for
  the game-server use case.
- **Ingress: keep Caddy on the host**, point at NodePort services. Don't
  introduce a second ingress controller; we already declare Caddy.
- **GitOps: Flux v2** reading manifests from creil. Lighter than
  ArgoCD; closer to "apply this directory" semantics.

## Could k8s replace static microvm guests?

Going through the inventory honestly:

- **Could run as a Pod**: phantasma (DNS/AdGuard), langport (nginx),
  oracion (Jellyfin, with VAAPI device plugin), tharbad (kube-prometheus-
  stack is the canonical case), creil (Forgejo), monrain (cgit), ardent
  (Attic), saint-arkh (the CI controller, not the runner daemon).
- **Could run as a KubeVirt VM**: messeldam (Keycloak+~100GB Postgres),
  altair (Headscale), longlai (subnet router) — same as today's microVM,
  different control plane.
- **Should not move**: basel (CA root keys are worse off in `Secret`
  resources than in microVM + sops-nix), the foundational guests on
  thebeyond, edith/trista (mutable NixOS dev environments are correct
  on Incus).

**Of these, only the kube-prometheus-stack on tharbad is a clearly
better fit on k8s.** Everything else is "could move, no real reason
to." A static-fleet migration is busywork unless we're committing to
k8s as the foundational platform — which is a much bigger decision
than the dynamic-layer question.

## Dual-firewall composition: keeping router6 authoritative

The single biggest architectural question if migrating: how do nftables
rules managed by NixOS (router6) compose with rules managed by a CNI?
Specifically — can we keep the static config as the authoritative
security boundary, with the CNI's firewall being **purely additive**
(can drop more, never permit more)?

**Short answer: yes, achievable, with the right CNI choice and a few
discipline rules. Real but bounded operational cost.**

### Mechanics — how rules from multiple sources compose

Both `nft` (native) and `iptables-nft` (compat shim) write to the same
kernel `nf_tables` backend. Multiple chains can attach to the same hook
(input, forward, output, prerouting, postrouting). Within a hook,
chains run in priority order, **and a packet must clear every chain to
pass — any chain dropping a packet drops it for everyone**.

Two firewalls don't act independently. They produce a single combined
verdict per packet. That's the foundation that makes "additive only"
feasible: if router6's chain says drop, the CNI cannot un-drop.

### Specific issues

#### a. Default-drop chains stack

If router6's forward chain is `policy drop` with explicit allows
(which it is) **and** the CNI installs anything default-drop, a
packet has to clear both. Risky when one firewall thinks it's
allowing but the other quietly drops.

**Mitigation:** pick a CNI with a small/zero footprint in shared
chains. Cilium with `kubeProxyReplacement=true` does almost all
enforcement in eBPF at the tc layer (before netfilter); its nftables
footprint is mostly empty. Calico in policy-only mode is similar.
Avoid kube-proxy in iptables/nftables mode, flannel's vxlan rules,
MetalLB.

#### b. `bridge-nf-call-iptables` decides whether intra-bridge L2
traffic hits L3 firewalling

The kernel sysctl `net.bridge.bridge-nf-call-iptables` (on by default
on most distros) makes pod-to-pod traffic on the same Linux bridge
hit router6's forward chain. With it off, bridged frames bypass
netfilter entirely.

**Implication:** if pods masquerade to node IPs and we use a
tunnelling CNI (Cilium VXLAN), cross-node pod traffic looks like UDP
between node IPs to router6 — clean and easy to reason about. If
pods get routable cluster-zone IPs and bridge-nf is on, router6
needs an explicit "cluster zone → cluster zone: accept" rule so
intra-cluster traffic isn't accidentally dropped.

#### c. NAT order matters when both sides do NAT

If the CNI installs DNAT for service IPs and router6 has masquerade
in postrouting, conntrack mediates and double-NAT generally works,
but the apparent source/destination at egress filtering changes
based on hook priorities.

**Mitigation:** **don't double-NAT.** Pick one of:
- Pods masquerade to host IP at the cluster's edge; router6 sees
  node-IP-as-source for all pod egress (simpler, loses per-pod
  visibility at the router level).
- Pods get routable IPs in their zone; no masquerade; router6 sees
  pod IPs (more router-visible policy, requires routing setup).

The first is normal and recommended for this homelab.

#### d. Reload races

NixOS's nftables module reloads by replacing managed rulesets. If it
flushes tables the CNI manages, the CNI has to reconcile (Cilium
and Calico both watch and re-install).

**Mitigation:** declare router6 chains via
`networking.nftables.tables.<name>` so NixOS only owns the tables it
declares. Don't set `flushRuleset = true`. The CNI's tables stay
untouched at NixOS reload.

#### e. Two debugging surfaces

When something doesn't work, you check both: `nft list ruleset` for
the host side and the CNI's tooling (`cilium policy trace`,
`calicoctl`, etc.) for the cluster side. Real ongoing cost — about
1.5x debug time for connectivity issues, not 2x because failure
modes are usually distinguishable (router6 drops appear in audit
counters; CNI drops appear in CNI tooling).

#### f. Don't mix iptables-nft and nft in the same chain

Calico uses `iptables-nft`; Cilium native nftables (or eBPF). Both
land in `nf_tables` but show up differently to inspection tools.
Pick one CNI; coexisting two would be operationally awful.

### How the "purely additive" property works

The user's hypothesis: router6 stays authoritative; CNI rules are
additive only (drop more, never permit more).

**This holds for the standard k8s policy model:**

1. router6 defines a `cluster` zone with explicit egress allows for
   what the cluster-as-a-whole may do: cluster → internet:443,
   cluster → creil:443 (registry), cluster → tharbad:9090
   (Prometheus), cluster → phantasma:53 (DNS), default-drop the rest.
2. Cluster nodes (kubelet hosts) sit in the `cluster` zone. Pod
   egress masquerades to the node IP, so router6 sees node-IP-as-
   source for everything leaving the cluster.
3. Inside the cluster: NetworkPolicy resources further restrict which
   pods talk to which other pods, and which pods may egress where.
   NetworkPolicy is **deny-after-allow**: it can only subtract from
   the underlying network's permitted set.

A pod whose NetworkPolicy "allows" egress to `8.8.8.8:53` but whose
node sits in a `cluster` zone that doesn't permit `→ 8.8.8.8:53`
just won't reach it. router6 is the ceiling. The CNI cannot grant
connectivity the host firewall denies.

The reverse is **not** true: router6 cannot enforce per-pod policy
because it can't tell which pod sent a masqueraded packet. Per-pod
policy lives in NetworkPolicy. That's the right layering — coarse
zone-level policy at router6, fine-grained per-pod policy inside the
cluster.

### What you give up

- **Type=LoadBalancer / MetalLB / hostPort.** All of these install
  rules that bypass or compete with router6. **Don't use them on
  this cluster.** Use `ClusterIP` + `NodePort` and front with the
  existing Caddy on the host. (This is also what the deployd model
  does today.)
- **Per-pod visibility at router6.** Pods are coarse-grained "any
  cluster pod" from router6's perspective.
- **Some CNI-native ingress controllers** that need to install host
  rules (most don't; ones that do are off-limits).

### Concrete config sketch (Cilium, the recommended option)

```nix
# router6: the cluster is its own zone with explicit egress allows
router6.zones.cluster = {
  icmpEcho = "disable";
  accessTo = [ "internet" ];   # host-level egress to internet
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
  # Caddy fronts the cluster via NodePort range
  inputRules = [
    { proto = "tcp"; saddr = langport.ipv4; dport = 30000-32767; }
  ];
};
```

```yaml
# cilium values (helm) — minimum-footprint config
kubeProxyReplacement: true
hostFirewall:
  enabled: false        # do NOT enforce host policy via cilium
ipam:
  mode: kubernetes
tunnelProtocol: vxlan   # pod-to-pod across nodes is UDP between nodes
bpf:
  masquerade: true      # pods masquerade to node IP at egress
ingressController:
  enabled: false        # we use host Caddy
gatewayAPI:
  enabled: false
```

With this configuration:

- router6 sees one source IP per node (node IP) for all pod egress.
- The cluster's permitted egress is **whatever the `cluster` zone
  allows in router6, intersected with whatever NetworkPolicy
  allows**. Both must allow.
- Pod-to-pod policy is fully governed by NetworkPolicy via Cilium's
  eBPF, with no router6 interaction.
- Cilium installs no rules in router6's tables; router6 reloads
  don't disturb Cilium's eBPF state.

### Pros of this dual setup

- **Trust boundary stays where it is.** router6 is authoritative;
  CNI failures or compromise cannot expand the cluster's permitted
  surface beyond what router6 whitelists.
- **Defense in depth.** A NetworkPolicy mistake (allow-all by
  accident) doesn't open the homelab to anything router6 hasn't
  pre-approved.
- **Right layering.** Coarse zone policy at router6, fine-grained
  per-pod policy at NetworkPolicy.
- **Fail-closed.** If the CNI is broken, the cluster is unreachable;
  rest of homelab unaffected. If router6 is broken, normal
  homelab-wide failure mode (same as today).

### Cons of this dual setup

- **1.5x debugging surface** for cluster connectivity issues.
- **Two reload paths.** A `nixos-rebuild` doesn't trigger Cilium
  reconciliation; a `kubectl apply` of a NetworkPolicy doesn't
  trigger router6 reload. Each tested separately.
- **Coarse zone-level policy at router6.** All pods are equivalent
  from router6's view. Sensitive workloads (CI runners pulling
  arbitrary code) and trusted workloads (the blog) share the same
  egress allowlist unless we split them across multiple cluster
  zones (doable, multiplies config).
- **Some k8s features off-limits.** Type=LoadBalancer, MetalLB,
  CNI-native ingress, hostPort — all conflict with router6.
- **Operational drift risk.** Over time, an operator adds a
  NetworkPolicy that opens egress to something router6 hasn't been
  told about, and developers see unexplained drops. The fail mode is
  fail-closed (good) but annoying. Mitigation: a single
  source-of-truth doc listing every "cluster needs to reach X"
  requirement and the rule in both layers.

### Net assessment

The "router6 authoritative, CNI additive only" model is the right
target architecture if going to k8s, and it's achievable. The
operational tax is real (~1.5x debugging, two reload cadences,
restricted feature set) but bounded. **The security property the
user is asking about — static config remains fully authoritative,
CNI cannot subtract from or expand it — is correct under this
design.**

The biggest watch-out is feature creep: every k8s tutorial assumes
LoadBalancer/MetalLB/CNI-ingress. We'd need a written "no, this
homelab does it via host Caddy" rule that's enforced in code review,
or those features will re-enter and start fighting router6.

## Mechanical prevention: rootless vs. microvm-confined k8s

Open question raised mid-evaluation: rather than relying on convention
("don't use LoadBalancer/MetalLB"), can we **mechanically** prevent
the cluster from touching router6's firewall configuration?

Yes, two ways. They have very different cost profiles.

### Option A — Rootless Kubernetes

Run the entire control plane (kubelet, apiserver, etcd, controllers)
in a user namespace via `rootlesskit`. From inside that namespace,
`CAP_NET_ADMIN` doesn't apply to the host's `nf_tables` — only to
the cluster's own network namespace. The CNI can install any rules
it likes; they only affect intra-cluster traffic.

**Real and significant costs:**

- **Network performance.** Rootless connectivity to the outside
  goes through `slirp4netns` or `pasta` — userspace TCP/UDP proxies.
  Pasta is the faster modern option but still costs 20–50%
  throughput and tens of µs of latency. CI image pulls and
  game-server UDP both feel it.
- **CNI choice is constrained.** Most CNIs assume root. Rootless
  typically lands on `flannel-rootless` or a heavily restricted
  Cilium. The eBPF datapath needs `CAP_BPF`/`CAP_PERFMON` plus
  unprivileged-BPF enabled in the host kernel, which hardened
  distros disable.
- **iSCSI CSI breaks.** `iscsiadm` and the kernel iSCSI initiator
  need `CAP_SYS_ADMIN` on the host. democratic-csi against the NAS
  doesn't work rootless — losing the volume-snapshot story that
  was one of the strongest k8s arguments for game servers.
- **Kata + rootless is uncharted.** Kata needs to invoke
  cloud-hypervisor / QEMU and access `/dev/kvm`. Rootless kata is
  documented as "possible with care" but isn't the well-trodden
  path. The friction we're hoping k8s reduces gets worse.
- **`/dev/kvm` for cc-sandbox** needs ACL grants and group
  membership. Workable, but more setup.

So rootless gets the security property but breaks two of the four
named workloads (game-server iSCSI, cc-sandbox nested KVM). Wrong
trade.

### Option B — k0s inside a microvm

Run a regular rootful k0s inside a microvm.nix guest, the same way
`roer` runs deployd-api today.

**Properties:**

- **Mechanical isolation by KVM, not by user namespaces.** The
  microvm's kernel has its own `nf_tables`. The host's `nf_tables`
  (router6) is unreachable across the hypervisor boundary — not a
  syscall question, a hardware question. No CNI can touch router6
  because there's no path.
- **CNI works normally** inside the microvm. Cilium with eBPF and
  `kubeProxyReplacement=true`, full feature set, because inside the
  microvm kubelet *is* root.
- **Network cost is one virtio-net boundary**, ~1–3% overhead, vs.
  20–50% for rootless.
- **CSI for iSCSI works** — the microvm runs `open-iscsi` itself,
  or the host attaches the LUN and passes it through as virtio-blk
  (same pattern as the deployd iSCSI spec).
- **Kata + nested KVM works** — erebonia already enables
  `kvm_intel nested=1`. Inside the microvm, kata-shim-v2 invokes
  cloud-hypervisor as usual.
- **`/dev/kvm` for cc-sandbox** is virtio-passed to the microvm,
  then a device plugin inside the cluster — same setup the cluster
  would need anyway.
- **router6 sees one interface** for the cluster (the microvm's
  vsock/bridge attachment). The cluster is one zone in router6,
  same kind of object as every other microvm guest. No new
  conceptual surface.

### Comparison

| Property | Rootless | k0s-in-microvm | Rootful on host |
| --- | --- | --- | --- |
| Can't mechanically touch router6 | yes (user ns) | yes (KVM) | no (convention) |
| CNI feature set | constrained | full | full |
| iSCSI / CSI | broken | works | works |
| Kata support | unproven | well-trodden | well-trodden |
| `/dev/kvm` for cc-sandbox | fragile | works | works |
| Network performance | 20–50% hit | ~1–3% hit | native |
| Existing pattern in repo | no | yes | no |

### Recommendation if migrating

**If we move to k8s, run it inside a microvm.** It gives the same
mechanical property the rootless option provides — k8s literally
cannot touch router6 — without the workload-breaking constraints.
And it fits the pattern the repo already uses for every other
isolated service.

This also reframes the "dual firewall" architecture: from router6's
perspective, the cluster is just one more guest. The cluster's
internal firewall (Cilium NetworkPolicy + whatever it installs in
its own kernel) is invisible to router6, and router6 is invisible
to the cluster. Each side reasons about its own firewall in
isolation. The 1.5x debugging surface from the dual-firewall
section above shrinks — instead of two firewalls on the same
host, it's one firewall per kernel, debugged via that kernel's
tooling.

The cost is the microvm boundary itself: one more guest to
provision, with cluster-control-plane resource needs (probably
2–4 GB RAM, 2 vCPU for k0s + a small workload). Acceptable.

## On-balance recommendation

This is closer than the previous pass made it sound. Two scenarios:

### Scenario A — extend deployd

**When this is right:**
- The homelab stays roughly the size it is now (one host running
  dynamic workloads).
- The operator prefers extending small audit-able Rust code over
  operating a kubelet+CNI+CSI stack.
- The named pain points (kata friction via nerdctl, missing
  iSCSI/snapshot story) are addressable in deployd in 3–6 months of
  work that is mostly already specced.

**Cost:** the operator owns the storage controller, the auth flow, and
the network management forever. Each new workload type adds custom
code.

### Scenario B — move the dynamic layer to k8s

**When this is right:**
- The homelab is a multi-year direction that wants to grow into
  multi-host scheduling, CI runner autoscaling, and possibly KubeVirt
  for new VM-shaped workloads.
- The operator wants to invest in k8s skills as a platform.
- The CSI / NetworkPolicy / RuntimeClass model maps cleanly onto the
  use cases (it does).

**Shape:** k0s or `services.kubernetes.*` on erebonia (single node to
start, calvard joinable later), Cilium policy-only, democratic-csi
against the NAS, Flux for manifests, Caddy retained on host, deployd
deprecated and removed once the four workload classes are migrated.

**Cost:** 6–12 months of careful migration work, ongoing
operational complexity tax, design work to keep router6 zones and
CNI policy in sync.

### My lean

If forced to pick today, I lean toward **Scenario A (stay)** for one
specific reason: the highest-leverage k8s wins (CI runner autoscaling,
CSI volume snapshots) are real but small in absolute terms at this
scale, and the in-flight containerd-gRPC migration removes the most
acute deployd pain point. The k8s investment doesn't pay for itself
until the homelab has more workloads than we can hand-roll one at a
time.

But this lean is genuinely 60/40, not the 90/10 the previous pass
implied. Scenario B is a defensible choice if the operator wants k8s
as a long-term platform direction. The previous "the spec already
rejected k3s" framing over-counted that decision: it was a different
question (k3s the distribution) at a different time.

## What this pass changes vs. the previous report

- Acknowledges that **k8s ≠ k3s**; the spec's k3s rejection doesn't
  generalize.
- Credits **kubelet + containerd + kata** as the genuinely-better
  integration path for the kata friction we've hit (vs. previously
  framing it as orthogonal).
- Credits **operator-ecosystem fit** for CI runners and game-server
  storage, which the previous pass dismissed too quickly.
- Distinguishes **`services.kubernetes.*` / k0s** from k3s as
  meaningfully different choices.
- Reframes the recommendation as **60/40 stay** rather than "obvious
  no" — Scenario B is a real option if the operator wants the
  platform investment.
