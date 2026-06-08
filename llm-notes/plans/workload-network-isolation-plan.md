# Workload Network Isolation & VLAN Placement — Plan

How the three workload substrates on the VM hosts (cloud-hypervisor microVMs,
KubeVirt VMs, and ordinary k3s containers/services) attach to the network: how
each is isolated from its host, how each gets a routable identity, and what
constrains *where* each can run. Records the decisions for the **current
single-node setup** (a deliberately non-invasive plan) and the **changes we'd
make** to get stronger isolation and/or a multi-node cluster without
host-pinned workloads.

Depends on / interacts with:

- `llm-notes/done/k3s-cluster-bootstrap-plan.md` — the cluster, **flannel CNI**,
  host firewall, NetworkPolicy controller. This plan layers on top of flannel
  and does **not** replace it (until the deferred Kube-OVN option below).
- `llm-notes/blocked/ai-dev-machine-kubevirt-plan.md` — owns the KubeVirt
  platform; its **Phase 5 (network lockdown) is BLOCKED on this plan.** Phase 5
  was revised to a defense-in-depth lockdown: shift the dev-machine VM onto the
  lesser-privileged **cluster VLAN with no host access** (Multus+bridge, multus-
  only) **plus** a NetworkPolicy egress allowlist. The VLAN-shift half is
  delivered here (Phases 1, 2, 4); the NetworkPolicy half is shared (Phase 6).
  Completing those unblocks it.
- `llm-notes/wip/k3s-cluster-workloads-plan.md` — the workloads that will want
  routable service IPs (blog, game servers, CI) and the dev layer. LB-IPAM here
  is how those become reachable.
- `lib/common/data/network.nix` — the registry. This plan adds a **cluster
  zone** and (optionally) delegates a subnet range to cluster IPAM.
- `hosts/erebonia/microvm/default.nix` — current microVM attachments (br11/br21
  bridges + macvtap for VLAN 50/100).
- `hosts/erebonia/k3s/default.nix` — k3s server; `trustedInterfaces = ["cni0"
  "flannel.1"]`, apiserver firewalling.

---

## Why

erebonia runs k3s all-in-one with **flannel**, which masquerades all pod egress
to the node's outbound interface — erebonia's **management address in VLAN 11**
(`10.97.11.31`). Consequences:

1. **Lateral over-access.** Every pod appears on the wire as a management-zone
   host and inherits whatever VLAN 11 can reach (Authelia, step-ca, Prometheus,
   NAS, WAN).
2. **Future WAN removal from VLAN 11.** We plan to strip general WAN from
   VLAN 11; today the cluster's WAN rides VLAN 11, so it would break.
3. **Routable identity wanted.** We want KubeVirt VMs (and select containers) to
   have their **own IPs and DNS entries**, routable like every other host —
   which flannel's single SNAT identity cannot provide.

A constraint that shapes everything: **erebonia must stay a management host.**
It is a multi-role box (k3s + Incus + microVM host); its management IP carries
SSH, fluent-bit→tharbad, NFS←liberl, and the apiserver SAN. The goal is **not**
to move the host off VLAN 11 — it is to move the *workloads' data plane and
identity* off VLAN 11, while the node keeps its management presence.

## The principle (applies to all three substrates)

> The host must never share a *trusted* L2 segment with its own guests, and the
> **router (zone firewall) — not a host bridge — is the policy enforcement
> point.** Every workload lives in a real zone; erebonia's management identity
> is its own thing, never shared with what it hosts.

The three substrates are mechanically distinct (different stacks), but they all
answer to this one principle and to the one policy plane (router6 zones).
Critically, **the k3s CNI choice does not reach the cloud-hypervisor microVMs**
— those are host-managed (microvm.nix → networkd taps), not Kubernetes objects,
so Kube-OVN/OVS could never govern them. "Unified" means *one principle, one
policy plane*, not one mechanism.

## Where we are now

| Substrate | Stack | Current attachment | Host isolation today |
| --- | --- | --- | --- |
| microVMs | cloud-hypervisor / microvm.nix | **macvtap** for VLAN 50/100 (`vm-50-*`, `vm-100-*`); **bridges** br11 (carries host mgmt IP) + br21 (no host IP) | macvtap: strong. br21: L3-isolated. **br11: weak** (shares host mgmt L2) |
| KubeVirt VMs | k3s + KubeVirt | none yet (platform landing per kubevirt-plan); VMs would default to flannel pod network | n/a yet |
| containers | k3s + flannel | flannel overlay, SNAT to host VLAN-11 IP | not isolated; egress = VLAN 11 |

---

## Decisions — current single-node setup (non-invasive)

The cluster is **single-node** today, so the placement constraints below are
**latent, not active** — there is only one place for anything to run. This plan
optimizes for *low invasiveness now* and documents the graduation path for when
multi-node/HA makes the constraints real.

**Keep flannel.** Multus and LB-IPAM are additive; no CNI replacement.

| Decision | Choice | Rationale |
| --- | --- | --- |
| microVM attachment | **macvtap for all** guests; **vepa or private** mode where sibling isolation is wanted | Host-isolated by construction; mode forces guest↔guest through the router. Already used for VLAN 50/100. |
| Retire shared br11 for guests | **Yes** — guests never sit on the host's management segment | br11 is the one weak isolation point (host mgmt IP shares L2). Guests move to their own zones. |
| KubeVirt VM attachment | **Multus + bridge CNI** on a **dedicated, host-IP-less bridge** over a VLAN subinterface | KubeVirt **cannot use macvlan/ipvlan** (it needs the pod iface MAC; bridge moves MAC to the VM). Bridge on a host-IP-less L2 → L3-isolated from host. |
| KubeVirt host-isolation completeness | **Per-VM choice:** *multus-only* (drop flannel primary → fully isolated, VLAN-native, no native cluster Service/DNS) **vs** *pod-network + bridge* (cluster-integrated, but flannel primary keeps host adjacency). Default dev-machines to **multus-only** (trista-in-k8s shape). | Out of the box a KubeVirt VM keeps the flannel pod NIC, and the host's `cni0` is adjacent. Only dropping it matches macvtap-grade isolation. |
| Container service routability | **LB-IPAM** (MetalLB **L2 mode** or Cilium LB-IPAM) handing out VIPs from a pool on the cluster VLAN; `external-dns` or static DNS for records | Most containers want a routable *service* IP, not a routable *pod* IP. Pods stay on flannel; only ingress gets an address. |
| Cluster egress off VLAN 11 | New **cluster zone/VLAN**; cluster data-plane egress rides it (per-pod via the LB/bridge VLANs they sit on; flannel-overlay egress optionally policy-routed out the cluster zone). Router6 governs the zone like any other. | Makes "remove WAN from VLAN 11" a one-line zone change, not a cluster rebuild. |
| Intra-cluster isolation | **NetworkPolicy** (kubevirt-plan Phase 5), default-deny per namespace | Defense-in-depth complement to the router doing inter-zone. |

### Network registry & DNS integration

This is what makes routable identity "simplify dev-machine integration" rather
than add bespoke plumbing:

1. **Add a `cluster` zone** to `lib/common/data/network.nix` (a `bt8gw`-owned
   VLAN — `11/12/20/21/50` are taken; `13`/`14` are free, TBD). Optionally a
   second cluster VLAN if we want workload-tier segmentation.
2. **Delegate a subnet range** to cluster IPAM: reserve a low band of host IDs
   for **pinned** workloads (registry-registered), and let IPAM (Whereabouts,
   or DHCP-via-Kea) own the churn above it.
3. **Pinned workloads** (dev-machines, key services) → **static IP** → registry
   entry → `mkUnboundLocalData` → phantasma authoritative DNS — the *same path*
   trista and saint-arkh already use. A dev VM becomes `dev-machine.internal`
   at its own routable address: SSH/kubectl/devpod straight to it, no NodePort,
   no port-forward, no ingress hop.
4. **Ephemeral pods** → dynamic pool, no DNS (or a delegated `*.k8s.internal`).
   If IPAM = **DHCP-via-Kea**, DNS falls out of the existing DHCP→DNS pipeline
   for free (natural for KubeVirt VMs, which DHCP like any machine).

---

## Known limitations of the current plan (all latent on single node)

These do not bite today (one node). They become real at multi-node/HA.

1. **KubeVirt + bridge VMs are node-pinned and cannot live-migrate.** A bridge
   NAD references a host interface; the VM can only schedule on **nodes where
   that L2 attachment exists** (VLAN trunked + subinterface + bridge + NAD
   replicated). And **bridge binding forfeits live migration** (memory/disk
   migrate, the bridge NIC does not). These VMs are doubly pinned — node pets
   that can at best *restart* elsewhere, not *roam*. **This is the sharp one.**
2. **microVMs are host-pinned** — but inherently (microvm.nix guests are
   per-host static definitions). macvtap adds nothing beyond "the host must
   carry that VLAN's uplink." Expected, not a regression.
3. **LB L2 mode funnels ingress.** One elected node answers ARP per VIP
   (failover, not balancing), and speaker nodes must have an interface on the LB
   VLAN. The *pods* still schedule anywhere (kube-proxy forwards). Constrains
   the *path*, not *where the workload runs*.
4. **KubeVirt host-isolation is a choice, not a default.** Keeping the flannel
   primary leaves host adjacency; only *multus-only* VMs are macvtap-grade
   isolated (at the cost of native in-cluster Service/DNS).
5. **Plain containers on flannel: no constraint** — freely schedulable. Good.

### The decision axis

Everything above reduces to one question: **do the dev-machine VMs need to move
between nodes?**

- **Pets on one box** (very plausible for LLM dev machines) → the non-invasive
  plan is correct; the placement "limitation" is a non-issue, even a feature
  (you *want* them pinned to a zone/node).
- **Must roam under HA** → bridge mode fights you. That is the trigger to
  graduate to Kube-OVN underlay (below).

---

## Future state A — stronger isolation (still flannel)

Incremental hardening that does not require replacing the CNI:

- **Default KubeVirt dev-machines to multus-only** (drop the flannel primary) so
  they are VLAN-native and host-isolated like the microVMs; reach cluster
  services via routed/LB paths rather than the pod network.
- **macvtap vepa/private everywhere** for microVMs so sibling traffic is forced
  through the router (currently `bridge` mode allows direct guest↔guest).
- **Tighten the cluster zone in router6** — explicit `accessTo`/`inputRules`,
  deny cluster→management except the few required flows (apiserver is already
  scoped to trusted+lab in `k3s/default.nix`).
- **NetworkPolicy default-deny** per namespace (kubevirt-plan Phase 5).

## Future state B — multi-node without host-pinned workloads (Kube-OVN underlay)

The single move that lifts the placement constraints **and** gives the cleanest
isolation is replacing flannel with **Kube-OVN in underlay/VLAN mode**:

- **Per-namespace `Subnet` CRDs bound to VLANs** via a provider network →
  cluster workloads live in real zones the router already firewalls.
- **Real routable IPs for pods *and* KubeVirt VMs**, with **static IP pinning**
  bound to the VM lifecycle and **DHCP** on the subnet for the rest.
- **IP preserved across live migration** (<0.5s downtime) — VMs roam; the
  bridge-mode no-migration pin disappears.
- **Host↔workload isolation is inherent** — workloads sit on OVN logical-switch
  ports, structurally separate from the host's kernel networking. The br11-style
  coupling cannot recur.
- The underlay subnet spans nodes via the provider network, so VM scheduling is
  no longer gated on per-node bridge/NAD replication.

**Cost:** replaces flannel (`--flannel-backend=none --disable-network-policy`),
adds OVS/OVN operational weight — the biggest moving piece in an otherwise
simple k3s. Justified only when VM mobility / per-namespace VLANs / multi-node
HA are firm goals.

**Convergence option (optional, later):** once on Kube-OVN, *non-foundational*
microVM workloads could fold into KubeVirt and share the underlay — making
microVM host-isolation the *same* problem as the cluster's. **Keep
foundational/bootstrap guests on microvm.nix regardless**, so they never depend
on the cluster being healthy.

### Triggers — when to make each change

| Trigger | Change |
| --- | --- |
| Removing WAN from VLAN 11 | Stand up the cluster zone + move cluster egress off VLAN 11 (current-plan item) — do this **first**, independent of everything else. |
| A dev VM must survive node maintenance / live-migrate | Move *that class* of VM to **Kube-OVN underlay** (future state B). |
| Adding a 2nd/3rd node for HA | Either replicate VLAN/bridge/NAD per node + accept restart-not-migrate, **or** adopt Kube-OVN underlay. Prefer underlay if VMs must roam. |
| LB L2 single-node ingress becomes a bottleneck | Switch LB to **BGP mode** (needs thebeyond/bt8gw to speak BGP). |
| Wanting per-workload-tier VLAN segmentation | Kube-OVN per-namespace subnets (future state B). |

---

## Phases / next steps (current plan)

1. **Cluster zone in the registry.** Add `cluster` (and optionally a 2nd
   segment) to `network.nix`; pick the VLAN id; reserve a static host-ID band;
   decide IPAM (Whereabouts vs DHCP-via-Kea). *No behavior change yet.*
2. **Cluster egress off VLAN 11.** Add `uplink.<vlan>` on erebonia; route
   cluster data-plane egress out it; add the `cluster` zone to router6 with
   explicit access. Unblocks the VLAN-11 WAN removal.
3. **microVM cleanup.** Convert remaining bridge guests to macvtap (vepa/
   private); retire guest use of br11.
4. **KubeVirt attachment.** Multus + bridge NAD on a host-IP-less bridge over
   the cluster VLAN; default dev-machines to multus-only; pin static IPs +
   registry/DNS for the named ones. (**Unblocks
   `ai-dev-machine-kubevirt-plan.md` Phase 5**, together with Phases 1–2.)
5. **Service routability.** Install LB-IPAM (MetalLB L2 to start); pool on the
   cluster VLAN; external-dns or static DNS.
6. **NetworkPolicy default-deny** (kubevirt-plan Phase 5).

## Open questions

- **Cluster VLAN id(s)** — `13`/`14` free under bt8gw; one zone or two (tier
  segmentation)?
- **IPAM** — Whereabouts (cluster-native) vs DHCP-via-Kea (free DNS, reuses
  router infra). DHCP-via-Kea is the more "in-grain" choice; confirm Kea can
  serve the cluster VLAN cleanly.
- **Do the dev-machine VMs need to roam?** — the axis that decides whether
  future state B is ever needed. Current assumption: **no** (pets), so the
  non-invasive plan stands and Kube-OVN stays deferred.
- **LB mode** — start L2; revisit BGP only if the ingress funnel bites.
