# Workload Network Isolation & VLAN Placement — Plan

**Status: WIP.** The **dev-machine / mobile critical-path slice** (Phases 1, 2
L2+fw4 without the flannel redirect, 4 + the wg-vpn rider — tracked in the
companion [`cluster-vlan-bringup-checklist.md`](cluster-vlan-bringup-checklist.md))
is **complete and proven 2026-06-10**: the locked-down dev VM runs on the
`cluster` VLAN 51 (multus-only macvtap), confined by bt8gw fw4, and is reachable
directly from mobile. The **broader phases remain deferred** (Future-state A/B,
the host-side flannel-egress redirect, LB-IPAM, NetworkPolicy default-deny,
dynamic-pool IPAM, removing WAN from VLAN 11) — see "Phases / next steps" and the
checklist's "Explicitly deferred".

How the three workload substrates on the VM hosts (cloud-hypervisor microVMs,
KubeVirt VMs, and ordinary k3s containers/services) attach to the network: how
each is isolated from its host, how each gets a routable identity, and what
constrains _where_ each can run. Records the decisions for the **current
single-node setup** (a deliberately non-invasive plan) and the **changes we'd
make** to get stronger isolation and/or a multi-node cluster without
host-pinned workloads.

Depends on / interacts with:

- `llm-notes/done/k3s-cluster-bootstrap-plan.md` — the cluster, **flannel CNI**,
  host firewall, NetworkPolicy controller. This plan layers on top of flannel
  and does **not** replace it (until the deferred Kube-OVN option below).
- `llm-notes/done/ai-dev-machine-kubevirt-plan.md` — owns the KubeVirt
  platform; its **Phase 5 (network lockdown) was unblocked by this plan's
  critical-path slice and is now PROVEN (2026-06-10).** Phase 5
  was revised to a defense-in-depth lockdown: shift the dev-machine VM onto the
  lesser-privileged **cluster VLAN with no host access** (Multus + macvtap,
  multus-only) **plus** a NetworkPolicy egress allowlist. The VLAN-shift half is
  delivered here (Phases 1, 2, 4); the NetworkPolicy half is shared (Phase 6).
  Completing those unblocks it. **But note the defense-in-depth caveat below:**
  for a _multus-only_ VM the NetworkPolicy half is inert (it governs only the
  flannel/pod plane), so the lockdown is really _router-enforced single-layer_ —
  the two plans should reconcile that framing. That plan's **Phase 6** (attach-only mobile/iPad
  access) also depends on this plan: it needs the routable VM + DNS (registry/DNS
  integration) **and** the `wg-vpn → cluster` firewall rider on Phase 4 below.
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
to move the host off VLAN 11 — it is to move the _workloads' data plane and
identity_ off VLAN 11, while the node keeps its management presence.

## The principle (applies to all three substrates)

> The host must never share a _trusted_ L2 segment with its own guests, and the
> **router (zone firewall) — not a host bridge — is the policy enforcement
> point.** Every workload lives in a real zone; erebonia's management identity
> is its own thing, never shared with what it hosts.

The three substrates are mechanically distinct (different stacks), but they all
answer to this one principle and to the one policy plane (router6 zones).
Critically, **the k3s CNI choice does not reach the cloud-hypervisor microVMs**
— those are host-managed (microvm.nix → networkd taps), not Kubernetes objects,
so Kube-OVN/OVS could never govern them. "Unified" means _one principle, one
policy plane_, not one mechanism.

## Where we are now

| Substrate    | Stack                          | Current attachment                                                                                               | Host isolation today                                                     |
| ------------ | ------------------------------ | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| microVMs     | cloud-hypervisor / microvm.nix | **macvtap** for VLAN 50/100 (`vm-50-*`, `vm-100-*`); **bridges** br11 (carries host mgmt IP) + br21 (no host IP) | macvtap: strong. br21: L3-isolated. **br11: weak** (shares host mgmt L2) |
| KubeVirt VMs | k3s + KubeVirt                 | none yet (platform landing per kubevirt-plan); VMs would default to flannel pod network                          | n/a yet                                                                  |
| containers   | k3s + flannel                  | flannel overlay, SNAT to host VLAN-11 IP                                                                         | not isolated; egress = VLAN 11                                           |

---

## Decisions — current single-node setup (non-invasive)

The cluster is **single-node** today, so the placement constraints below are
**latent, not active** — there is only one place for anything to run. This plan
optimizes for _low invasiveness now_ and documents the graduation path for when
multi-node/HA makes the constraints real.

**Keep flannel.** Multus and LB-IPAM are additive; no CNI replacement.

| Decision                             | Choice                                                                                                                                                                                                                                                                                                                                                                                                                                      | Rationale                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| microVM attachment                   | **macvtap for all** guests; **vepa or private** mode where sibling isolation is wanted                                                                                                                                                                                                                                                                                                                                                      | Host-isolated by construction. `private` blocks same-host siblings outright; `vepa` forces them up to the **upstream switch** (router mediation only for _inter-zone_/inter-subnet hops — the router never routes intra-subnet, and same-VLAN reflection needs switch reflective-relay support). Already used for VLAN 50/100. |
| Retire shared br11 for guests        | **Yes** — guests never sit on the host's management segment                                                                                                                                                                                                                                                                                                                                                                                 | br11 is the one weak isolation point (host mgmt IP shares L2). Guests move to their own zones.                                                                                                                                                                                                                                 |
| KubeVirt VM attachment               | **Multus + macvtap** on a VLAN subinterface (`uplink.51`). **(Revised 2026-06-10** — was "Multus + bridge CNI on a host-IP-less bridge.")                                                                                                                                                                                                                                                                                                  | The original rationale ("KubeVirt cannot use macvlan/ipvlan — it needs the pod iface MAC; bridge moves MAC to the VM") conflated the macvlan **CNI** with KubeVirt's **macvtap binding plugin**, which *does* work (macvlan-family, host↔guest isolated). The bridge path was then forced out anyway: k3s' `bridge-nf-call=1` drags a host-bridge's VLAN-51 frames through `br_netfilter`, which silently drops routed-in (`lab → dev-N`) traffic. macvtap is not a bridge → never enters `br_netfilter`, and matches the VLAN 50/100 microVM pattern. See [`../wip/dev-machine-vlan51-macvtap-cutover.md`](../wip/dev-machine-vlan51-macvtap-cutover.md). |
| KubeVirt host-isolation completeness | **Per-VM choice:** _multus-only_ (drop flannel primary → fully isolated, VLAN-native, no native cluster Service/DNS) **vs** _pod-network + macvtap_ (cluster-integrated, but flannel primary keeps host adjacency). Default dev-machines to **multus-only** (trista-in-k8s shape).                                                                                                                                                           | Out of the box a KubeVirt VM keeps the flannel pod NIC, and the host's `cni0` is adjacent. Only dropping it matches macvtap-grade isolation — and with macvtap binding the secondary NIC is itself host↔guest isolated by construction.                                                                                          |
| Container service routability        | **LB-IPAM** (MetalLB **L2 mode** or Cilium LB-IPAM) handing out VIPs from a pool on the cluster VLAN; `external-dns` or static DNS for records                                                                                                                                                                                                                                                                                              | Most containers want a routable _service_ IP, not a routable _pod_ IP. Pods stay on flannel; only ingress gets an address.                                                                                                                                                                                                     |
| Cluster egress off VLAN 11           | New **cluster zone/VLAN**; each tier reaches VLAN 51 by its own mechanism — dev VMs via multus + macvtap (own IP via bt8gw DHCP reservation), services via LB-IPAM VIPs, **plain flannel pods via source-based policy routing + masquerade onto a host VLAN-51 egress address** (concrete design in "The three tiers" below). **VLAN 51 terminates on bt8gw, so the enforcing firewall is bt8gw's fw4 (manual UCI), not router6** — see "Where VLAN 51 terminates" below. | Makes "remove WAN from VLAN 11" a contained fw4 change on bt8gw, not a cluster rebuild.                                                                                                                                                                                                                                        |
| Intra-cluster isolation              | **NetworkPolicy** (kubevirt-plan Phase 5), default-deny per namespace                                                                                                                                                                                                                                                                                                                                                                       | Complements the router for **pod-network (flannel) workloads**. NB: it does **not** govern a multus-only VM's macvtap data plane — see limitation #4 and the defense-in-depth caveat below.                                                                                                                                     |

### Network registry & DNS integration

This is what makes routable identity "simplify dev-machine integration" rather
than add bespoke plumbing:

1. **Add a dedicated low-trust `cluster` zone** to
   `lib/common/data/network.nix` on **VLAN 51** (`bt8gw`-owned, adjacent to
   `app`/50 → `10.97.51.0/24`, ULA `fdc6:55f2:0a5e:1033::/64`). This is **one
   new zone for the low-trust tier** (dev-machine sandboxes, future
   friend-facing workloads) — **not** a general cluster zone for everything. See
   "Why a dedicated zone, not `app`" below; trusted, app-natured cluster
   services may instead attach to the existing `app` zone.
2. **Delegate a subnet range** to cluster IPAM, with a non-overlapping host-ID
   map for VLAN 51: `.1` = bt8gw gateway; a **named dev-slot band**
   (`dev-1`..`dev-16` = `.10`..`.25`, registry-registered — see #3); an
   **erebonia flannel-egress** address (see "The three tiers"); a **LB-IPAM VIP
   pool**; and a **dynamic pool** owned by IPAM (Whereabouts, or bt8gw DHCP) for
   anything beyond the named slots. **Registry constraint:** erebonia's egress
   address **cannot** be a `cluster`-zone registry host under the name
   `erebonia` — `network.nix`'s `dupHostnames` check throws on a hostname that
   already exists in another zone (erebonia is in `management`). So make it a
   hardcoded static in erebonia's networkd, or register it under a distinct name
   (e.g. `erebonia-cluster`). Same rule applies to any host that needs both a
   management and a cluster identity.
3. **Pinned workloads** (key services) → **static IP** → registry entry →
   `mkUnboundLocalData` → phantasma authoritative DNS — the _same path_ trista
   and saint-arkh already use. **Dev machines use a named-slot variant of this:**
   instead of one `dev-machine` host (which wrongly assumes exactly one dev VM),
   the registry declares **16 static slots `dev-1`..`dev-16`** (`network.nix`
   `cluster` zone, generated via `lib.genList`). The _names/IPs are static_
   (registered once → DNS for `dev-N.internal` flows automatically); the
   _occupancy is dynamic_ — a launcher assigns a free slot's IP/MAC to each
   ephemeral KubeVirt dev VM at create time, so spinning machines up/down needs
   **no registry edit**. This reuses the authoritative DNS path (non-spoofable,
   no new infra), keeps the direct-to-sandbox security model, and gives
   mobile-by-name reach (`mosh dev@dev-N.internal`) — at the cost of a static cap
   (16; widen the `genList` count into the band's `.26–.31` headroom).
   _Considered and rejected for now:_ (a) **bt8gw dnsmasq DHCP→DNS** — dnsmasq
   does register DHCP hostnames as DNS dynamically (unbounded, no cap), but the
   names are self-asserted/spoofable, it needs a stub/NS **delegation** of a
   `dev.internal` subdomain from kresd/phantasma to bt8gw, and it adds DNS work on
   the hand-managed bt8gw; (b) a **cluster-as-nameservice broker** (attach by
   KubeVirt VM name) — cleanest identity but re-introduces a hop and risks
   mobile↔control-plane reach, against the P5/P6 threat model.
4. **Ephemeral pods / unnamed VMs beyond the 16 slots** → dynamic pool, no DNS
   (or a delegated `*.k8s.internal`). Note the registry→phantasma path is
   authoritative `.internal`; **no DHCP server here feeds `.internal` DNS** (see
   the IPAM open question), so the dynamic tier is addressed by IP unless one of
   the dynamic-DNS options below is adopted.

> **Eventual direction — programmatic DNS via knot-resolver (kresd).** If the 16
> static slots are outgrown (many concurrent, churny, project-named dev VMs that
> want real names without a cap), the cleanest next step is **programmatic record
> management against kresd's control API** rather than DHCP-self-naming: a
> launcher injects/removes `dev-<name>.internal` A/AAAA records at VM create/
> destroy via kresd (knot-resolver) at runtime — authoritative, non-spoofable
> (the launcher is the only writer), unbounded, and no rebuild/redeploy. This is
> a **possible future**, not part of the current slice; the named slots cover the
> near term. (Compare the rejected bt8gw-dnsmasq DHCP→DNS path in #3, which is
> dynamic but self-asserted and hand-managed.)

### Where VLAN 51 terminates — bt8gw fw4, not router6

VLAN 51 is currently **unowned**; it will be **bt8gw-owned and bt8gw-terminated**
(its address space is `10.97.x`, and it sits adjacent to `app`/50, which already
terminates on bt8gw). erebonia — where the cluster runs — is itself bt8gw-side
(VLAN 11). So the natural and intended L3 home for VLAN 51 is **bt8gw**, and that
has consequences this plan must own, because **bt8gw runs OpenWrt fw4, not
router6, and its firewall is hand-managed via UCI/LuCI** (`guides/bt8-gateway-
luci-runbook.md`, `bt8-gateway-as-built.md`) — it is **not built from this
flake**.

Concretely:

- **router6 needs nothing for `cluster` — not even a naming stub.** (Corrected
  during Phase A; an earlier draft said to declare a stub in thebeyond's
  `router6.zones` "so cross-zone references can name it," by analogy to `app`.
  That is wrong.) On thebeyond a zone is load-bearing only if an interface binds
  to it (`network.zone`, enum-typed), another zone names it in `accessTo`
  (enum-typed), or another zone names it as a `forwardRules` key (router6 asserts
  the key is a real zone). **None happens for `cluster`, and none can:** `cluster`
  is bt8gw-owned, so thebeyond reaches it only _across
  the gateway split via `transit`_ — exactly why the existing `transit` rules
  gate the "transit→app side" by `daddr` instead of naming an `app` zone.
  Interface-less zones are also dropped from `activeZones` (emit zero rules).
  Verified: deleting the stub leaves thebeyond's rendered nftables ruleset clean
  with no `cluster` reference. (The pre-existing `app` stub is dead weight for
  the same reason; left in place, out of scope.) thebeyond does **not** enforce —
  or even name — the cluster policy.
- **The real enforcement is bt8gw fw4 (manual UCI).** `cluster → app: allow
creil:{22,443}, zeiss:443` + DNS + `cluster → *: deny`, and "cluster egress
  off VLAN 11",
  are **fw4 rules on bt8gw**, authored in the established UCI style (cf. the
  dual-gateway checklist's `temp/BT8-gw-phase-5a-additions.uci` + as-built
  notes), not Nix. Budget this as LuCI/UCI runbook work, not a router6 edit.
- **DHCP for VLAN 51 is bt8gw's, not router6's Kea.** A bt8gw-terminated VLAN is
  served by bt8gw's odhcpd/dnsmasq. The "DHCP-via-Kea → free DNS pipeline" idea
  in the registry section only holds if Kea actually owns the segment — which it
  does **not** if VLAN 51 terminates on bt8gw. See the IPAM open question.
- **Standing up the VLAN is multi-device L2 work.** Not just "add `uplink.51` on
  erebonia": bt8gw needs the tag in its `br0` bridge-vlan filtering (+ an
  L2-passthrough bridge), and the mesh trunk must carry tag 51 to erebonia (cf.
  the VLAN-11/20/21 deviation note in the dual-gateway checklist), before
  erebonia's subinterface/bridge exists.

This does not change the _design_ — the router is still the policy plane and the
cluster lives in a real zone — but the plan's "router6 governs it" / "one-line
zone change" phrasing is wrong about the _work surface_. The enforcing device is
bt8gw, and its config is manual.

### The three tiers of VLAN 51 identity (and what stays on flannel)

"Cluster on VLAN 51" is **not** one mechanism. flannel is unchanged — it still
masquerades pod egress — so nothing becomes VLAN-51-routable by virtue of being a
pod. Three distinct tiers each gain a VLAN 51 presence a different way, and
erebonia's **management identity stays entirely on VLAN 11** throughout
(`10.97.11.31`: apiserver `:6443`, SSH, NFS←liberl, fluent-bit).

| Tier                          | VLAN 51 identity                                       | Mechanism                                                                                                                                                                         |
| ----------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Dev-machine VMs (multus-only) | **a named slot IP** (`dev-1`..`dev-16` = `.10`..`.25`) | multus + macvtap; flannel bypassed entirely for the VM. Launcher assigns a free static slot → pins a deterministic per-slot MAC → bt8gw DHCP reservation yields the slot IP → registry → DNS (`dev-N.internal`). bt8gw firewalls the slot band (uniform dev policy). |
| Container services            | **LB VIP** on VLAN 51                                  | LB-IPAM (MetalLB L2) — node ARPs the VIP, kube-proxy DNATs. Pods behind it stay on flannel + SNAT internally; only the ingress VIP is on 51.                                      |
| General flannel pods          | **SNAT'd to the host egress IP** (`10.97.51.31`)       | source-based policy routing + flannel's existing masquerade (below). All pods appear to bt8gw as this one source.                                                                 |
| erebonia (host)               | **egress-only `10.97.51.31`, input default-drop**      | static addr on a _separate_ iface from the VM bridge; host is L3-firewalled off VLAN 51 (below).                                                                                  |
| erebonia management           | **stays VLAN 11** (`10.97.11.31`)                      | unchanged.                                                                                                                                                                        |

**General-pod egress — concrete design.** This replaces the old "optionally
policy-routed" hand-wave; it is required (not optional) once WAN leaves VLAN 11,
because that is the only thing that gets ordinary pod egress off VLAN 11. On
erebonia:

1. **Static VLAN-51 egress address**, e.g. `10.97.51.31/24` — present but **not**
   a default route (the host's default stays VLAN 11). Put it on an interface
   **separate from the KubeVirt VM bridge** (a macvlan on `uplink.51`, or
   `uplink.51` itself L3 while the VM bridge is its own construct) so the **VM
   bridge stays host-IP-less** — otherwise the host's L3 lands on the guests'
   bridge and that is a (milder, low-trust) br11 recurrence.
2. **Source-based policy routing** for the pod CIDR: `ip rule add from
10.42.0.0/16 lookup cluster-egress`, with table `cluster-egress` carrying
   `default via 10.97.51.1 dev <egress-iface>` (bt8gw is the VLAN 51 gateway).
3. **Scope it so pod→pod and pod→Service stay on-cluster** — add higher-priority
   `from 10.42.0.0/16 to 10.42.0.0/16 lookup main` and `… to 10.43.0.0/16 lookup
main` (or replicate the cluster routes into `cluster-egress`). Without this
   the lone `default` swallows overlay and ClusterIP traffic. **This is the
   fiddliest bit.**
4. **No flannel change.** flannel already masquerades `10.42.0.0/16 →
!10.42.0.0/16`; once the route sends that traffic out the VLAN-51 iface, the
   masquerade source becomes `10.97.51.31` automatically. The custom `ip
rule`/route + static addr are bespoke networkd/nftables on erebonia that must
   coexist with flannel's iptables and survive flannel restarts — budget it as
   real config, not a k3s flag.

**Host firewalled completely off VLAN 51 — and it costs nothing.** erebonia
**default-drops all input** on the VLAN-51 egress iface (it is **not** a
`trustedInterface`; flannel only needs `cni0`/`flannel.1` trusted, which it
already has). This does not break pod egress: pod traffic is **FORWARD** (+ SNAT
in POSTROUTING), and conntrack reverses the SNAT _before_ the routing decision on
replies, so return traffic is also FORWARD — **neither hits the INPUT chain**.
Only a _new_ connection addressed to `10.97.51.31` itself hits INPUT, which is
exactly what we drop. apiserver `:6443` and SSH are already allowlisted to
trusted+lab only, so VLAN 51 cannot reach them regardless. Net: the host's VLAN
51 presence is a pure egress NAT address in the low-trust zone, with zero
inbound surface.

**Residual.** All flannel pods share one source IP at bt8gw, so the router
cannot tell pods apart — fine for general workloads, and precisely why the
locked-down dev sandbox stays **multus-only with its own IP** (so bt8gw _can_
firewall it distinctly); per-pod control inside the cluster stays NetworkPolicy's
job. Host and VMs remain L2-adjacent on VLAN 51, but in the low-trust zone with
the host L3-firewalled off — categorically smaller than br11 (which shared the
_management_ identity). The only strictly-better option is Kube-OVN underlay
(real per-pod IPs, no SNAT) — future state B.

### Why a dedicated zone, not the existing `app` tier

The cluster's general _services_ could ride `app` (VLAN 50) — but the
**dev-machine sandbox cannot**, and that is what drives the new zone:

- **The router only firewalls _between_ zones.** Intra-zone traffic is
  L2-switched across the VLAN-50 broadcast domain (which already spans
  calvard/liberl/erebonia over the mesh trunk) and never reaches the router.
- **The sandbox's entire allowlist lives in `app`:** `creil` (git, id 53) and
  `zeiss` (Attic, id 31) are both VLAN 50. Put the sandbox in `app` and it
  reaches them _and_ `oracion`/`saint-arkh`/all of VLAN 50 on **any port with
  zero router mediation** — Layer 1 evaporates and the lockdown collapses to
  NetworkPolicy-only (the posture the block exists to fix).
- **Router-enforced lockdown requires the sandbox in a _different_ zone than its
  targets:** `cluster → app: allow creil:{22,443}, zeiss:443` + DNS + `cluster →
*: deny`. That rule is only expressible across a zone boundary.
  (`creil:22` = git SSH push; `creil:443` = HTTPS workspace clone **and**
  container-registry pull of the dev image — the bring-up notes' `/v2/`
  large-layer path; `zeiss:443` = Attic. DNS to the VLAN-51 resolver, since a
  multus-only VM has **no** in-cluster DNS.)
- **Blast radius:** `app` holds operator-controlled infra (Forgejo, Attic,
  Jellyfin, CI). Co-locating untrusted agent code L2-adjacent to it (ARP games,
  any-port reach) is strictly worse than letting the router mediate. The same
  objection rules out reusing `lab` or `untrusted`.

**Resolution:** one new low-trust `cluster` zone for sandboxes (and future
friend-facing workloads); trusted cluster services may reuse `app` via their own
NAD. The Multus attachment is per-workload, so the two coexist without a second
new zone. The only way to avoid the new zone entirely is to drop Layer 1 and accept
the NetworkPolicy-only interim.

---

## Known limitations of the current plan (all latent on single node)

These do not bite today (one node). They become real at multi-node/HA.

1. **KubeVirt macvtap VMs are node-pinned and cannot live-migrate.** The macvtap
   NAD references a host interface (`uplink.51`); the VM can only schedule on
   **nodes where that L2 attachment exists** (VLAN trunked + subinterface +
   macvtap-cni device plugin + NAD replicated). And **macvtap binding forfeits
   live migration** (memory/disk migrate, the host-tied macvtap NIC does not — the
   same limitation the bridge binding had). These VMs are doubly pinned — node
   pets that can at best _restart_ elsewhere, not _roam_. **This is the sharp
   one.**
2. **microVMs are host-pinned** — but inherently (microvm.nix guests are
   per-host static definitions). macvtap adds nothing beyond "the host must
   carry that VLAN's uplink." Expected, not a regression.
3. **LB L2 mode funnels ingress.** One elected node answers ARP per VIP
   (failover, not balancing), and speaker nodes must have an interface on the LB
   VLAN. The _pods_ still schedule anywhere (kube-proxy forwards). Constrains
   the _path_, not _where the workload runs_.
4. **KubeVirt host-isolation is a choice, not a default — and it trades off
   against NetworkPolicy.** Keeping the flannel primary leaves host adjacency;
   only _multus-only_ VMs are macvtap-grade isolated (at the cost of native
   in-cluster Service/DNS). **Crucially, the two postures are near-mutually-
   exclusive on this stack:** k3s NetworkPolicy (kube-router) only enforces on
   the flannel/pod network, so a **multus-only VM's VLAN-51 egress is outside
   NetworkPolicy entirely** — the router (bt8gw fw4) is its _sole_ enforcer.
   Conversely, pod-network + macvtap gets real NetworkPolicy but weakens Layer 1.
   You cannot get strong-Layer-1 **and** Layer-2 on the same VM here; genuine
   two-layer on a secondary network needs Multi-NetworkPolicy or a policy engine
   that covers secondary nets (Calico multi-net / Kube-OVN — future state B).
   This is **not latent** — it bites on the single node today. See the
   defense-in-depth caveat below.
5. **Plain containers on flannel: no constraint** — freely schedulable. Good.

> **Defense-in-depth caveat (reconcile with kubevirt-plan Phase 5).** That
> plan's revised Phase 5 sells _Layer 1 (multus-only VLAN shift) **plus** Layer 2
> (NetworkPolicy default-deny egress)_ as two enforced layers on the **same**
> dev VM. Per limitation #4 that is not achievable on k3s+flannel+kube-router:
> defaulting dev-machines to multus-only makes Layer 2 **inert for their data
> plane**, leaving bt8gw fw4 as the single (strong) enforcer. This is a fine
> posture — but it is **router-enforced single-layer**, not defense-in-depth.
> The plans should agree on one story per VM: either (a) multus-only +
> router-only (recommended for the dev sandboxes; accept Service/DNS loss and
> drop the NetworkPolicy-on-the-same-VM claim), or (b) pod-network+bridge +
> NetworkPolicy (weaker Layer 1). The shared "Phase 6 NetworkPolicy half" below
> only meaningfully unblocks kubevirt Phase 5 under posture (b), or for
> _other_ pod-network workloads in the namespace — not for a multus-only VM.

### The decision axis

Everything above reduces to one question: **do the dev-machine VMs need to move
between nodes?**

- **Pets on one box** (very plausible for LLM dev machines) → the non-invasive
  plan is correct; the placement "limitation" is a non-issue, even a feature
  (you _want_ them pinned to a zone/node).
- **Must roam under HA** → bridge mode fights you. That is the trigger to
  graduate to Kube-OVN underlay (below).

---

## Future state A — stronger isolation (still flannel)

Incremental hardening that does not require replacing the CNI:

- **Default KubeVirt dev-machines to multus-only** (drop the flannel primary) so
  they are VLAN-native and host-isolated like the microVMs; reach cluster
  services via routed/LB paths rather than the pod network.
- **macvtap vepa/private everywhere** for microVMs so sibling traffic stops
  going direct (currently `bridge` mode allows direct guest↔guest). `private`
  blocks same-host siblings; `vepa` hairpins them to the upstream switch (router
  mediation applies only across zones/subnets, not within a VLAN).
- **Tighten the cluster zone on bt8gw fw4** (the enforcing device — see "Where
  VLAN 51 terminates") — explicit per-flow accepts, deny cluster→management
  except the few required flows (apiserver is already scoped to trusted+lab in
  `k3s/default.nix`'s host firewall; the dev VM, being in `cluster` not
  trusted/lab, cannot reach it — intended).
- **NetworkPolicy default-deny** per namespace (kubevirt-plan Phase 5).

## Future state B — multi-node without host-pinned workloads (Kube-OVN underlay)

The single move that lifts the placement constraints **and** gives the cleanest
isolation is replacing flannel with **Kube-OVN in underlay/VLAN mode**:

- **Per-namespace `Subnet` CRDs bound to VLANs** via a provider network →
  cluster workloads live in real zones the router already firewalls.
- **Real routable IPs for pods _and_ KubeVirt VMs**, with **static IP pinning**
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

**Convergence option (optional, later):** once on Kube-OVN, _non-foundational_
microVM workloads could fold into KubeVirt and share the underlay — making
microVM host-isolation the _same_ problem as the cluster's. **Keep
foundational/bootstrap guests on microvm.nix regardless**, so they never depend
on the cluster being healthy.

### Triggers — when to make each change

| Trigger                                               | Change                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Removing WAN from VLAN 11                             | Stand up the cluster zone + the host-side flannel-egress redirect onto VLAN 51 (Phase 2 — L2 + bt8gw fw4 + erebonia policy-routing/masquerade) — do this **first**, independent of everything else. The host-side redirect is **required, not optional**: it is the only thing that gets ordinary pod egress off VLAN 11. |
| A dev VM must survive node maintenance / live-migrate | Move _that class_ of VM to **Kube-OVN underlay** (future state B).                                                                                                                                                                                                                                                        |
| Adding a 2nd/3rd node for HA                          | Either replicate VLAN/bridge/NAD per node + accept restart-not-migrate, **or** adopt Kube-OVN underlay. Prefer underlay if VMs must roam.                                                                                                                                                                                 |
| LB L2 single-node ingress becomes a bottleneck        | Switch LB to **BGP mode** (needs thebeyond/bt8gw to speak BGP).                                                                                                                                                                                                                                                           |
| Wanting per-workload-tier VLAN segmentation           | Kube-OVN per-namespace subnets (future state B).                                                                                                                                                                                                                                                                          |

---

## Phases / next steps (current plan)

> **Execution.** The dev-machine / mobile critical path through these phases
> (Phases 1, 2-without-the-flannel-redirect, 4 + rider) is tracked step-by-step
> in the companion [`cluster-vlan-bringup-checklist.md`](cluster-vlan-bringup-checklist.md)
> — it unblocks `ai-dev-machine-kubevirt-plan.md` Phase 5 and Phase 6 pieces 5–6.

1. **Cluster zone in the registry.** Add `cluster` (and optionally a 2nd
   segment) to `network.nix`; pick the VLAN id; reserve a static host-ID band;
   decide IPAM (Whereabouts vs DHCP-via-Kea). _No behavior change yet._
2. **Cluster egress off VLAN 11.** Three sub-steps (see "Where VLAN 51
   terminates" + "The three tiers of VLAN 51 identity"):
   - **L2 plumbing.** Trunk tag 51 across bt8gw (`br0` bridge-vlan +
     L2-passthrough bridge) and the mesh to erebonia, then add `uplink.51` on
     erebonia.
   - **bt8gw fw4 (manual UCI).** Terminate VLAN 51 there (it owns the
     `10.97.51.1` gateway + DHCP), add the `cluster` zone, and grant it the WAN
     - cross-zone flows general pods need. **No thebeyond `router6.zones` change
       is needed** — thebeyond never names a bt8gw-owned zone (it reaches it only
       across the gateway split via `transit`), so no naming stub is required.
       See "Where VLAN 51 terminates" above for the verification.
   - **erebonia host-side flannel egress.** Static `10.97.51.31` on an iface
     **separate from the dev-VM macvtap path** (the dev VMs hold no host iface —
     macvtap gives the host no VLAN-51 L3 presence — so add a dedicated egress
     iface only for the flannel tier);
     source-based policy routing of the pod CIDR out VLAN 51 (scoped so
     pod→pod/Service stay on-cluster); flannel's masquerade then sources from
     `10.97.51.31`; **default-drop all input on the VLAN-51 iface** (host fully
     firewalled off — pod traffic is FORWARD, so this costs nothing). Concrete
     `ip rule`/table design in "The three tiers."

   Unblocks the VLAN-11 WAN removal.

3. **microVM cleanup.** Convert remaining bridge guests to macvtap (vepa/
   private); retire guest use of br11.
4. **KubeVirt attachment.** Multus + **macvtap** NAD over the cluster VLAN
   (`uplink.51`); default dev-machines to multus-only; pin per-slot IPs via
   **bt8gw DHCP reservations** (keyed on the launcher's deterministic per-slot MAC)
   + registry/DNS for the named ones. (**Unblocks `ai-dev-machine-kubevirt-plan.md`
   Phase 5**, together with Phases 1–2.) **Status 2026-06-10: flake side +
   reservations done; cluster apply + runtime verify remain** (see the bring-up
   checklist Phase D and the macvtap cutover note).
   - **Rider — `wg-vpn → cluster` allowance for mobile dev-machine access**
     (unblocks `ai-dev-machine-kubevirt-plan.md` **Phase 6**, the attach-only
     mobile/iPad path). Once the named dev VMs are routable + DNS'd (above), add
     a **scoped** rule: `daddr` = the dev-machines host band on VLAN 51, **TCP
     `:22`** (mosh/ssh session bootstrap) **+ UDP `60000–61000`** (mosh data).
     **Enforcement is on bt8gw, not thebeyond.** `wg-vpn` terminates on
     thebeyond and `cluster` on bt8gw, and `wg-vpn.accessTo` already includes
     `transit`, so thebeyond _already_ forwards `wg-vpn → 10.97.0.0/16` broadly
     (gated only by bt8gw fw4 — the standard cross-gateway model). The new rule
     is therefore a **bt8gw fw4** `transit → cluster` accept with `saddr =
10.100.10.21` (the `mobile` peer) scoped to the dev-machines band + those
     ports — **not** a router6 `wg-vpn` zone edit. Keep it narrowed to the band,
     not the whole `cluster` zone; this is the one deliberate hole into
     `cluster`. The mobile reuses the existing `wg-vpn` `mobile` peer; no new VPN
     infra. Lifecycle stays on edith, so this opens no path to the control plane.
5. **Service routability.** Install LB-IPAM (MetalLB L2 to start); pool on the
   cluster VLAN; external-dns or static DNS.
6. **NetworkPolicy default-deny** (kubevirt-plan Phase 5).

## Open questions

- **Cluster VLAN id** — **Resolved: VLAN 51** (bt8gw-owned, adjacent to
  `app`/50). One new low-trust `cluster` zone (not `app`, not two zones) — see
  "Why a dedicated zone, not `app`".
- **IPAM (low-stakes — only the ephemeral tier)** — **Whereabouts**
  (cluster-native) vs **bt8gw DHCP** (same dnsmasq/odhcpd bt8gw already runs for
  VLAN 20, etc.). The original "DHCP-via-Kea → free DNS pipeline" framing is
  **dead**: Kea runs in router6 on **thebeyond**, but VLAN 51 terminates on
  **bt8gw**, and — more fundamentally — **no DHCP server here feeds DNS for
  free.** Network-wide resolution goes kresd→**phantasma authoritative
  `.internal`**, not through any DHCP server; a bt8gw lease yields an address but
  no resolvable `.internal` record (same as VLAN 20 today — azoth resolves only
  because it's a registry host → `mkUnboundLocalData`, not because bt8gw leased
  it). Consequences:
  - **Named hosts are static + registry + `mkUnboundLocalData` regardless of the
    IPAM choice** (this is what mobile-by-name access needs). The **16 dev slots**
    are exactly this: the `.internal` record is the registry's, served by
    `mkUnboundLocalData` — independent of however the address is leased.
  - **Resolved for the dev tier (2026-06-10): bt8gw DHCP reservations.** The
    macvtap cutover settled the dev-slot IPAM: macvtap does no in-pod DHCP, so the
    guest DHCPs from bt8gw, and the launcher pins a **deterministic per-slot MAC**
    (`02:51:51:00:00:<hex(9+N)>`) that bt8gw reserves to the slot's registry IP
    (`10.97.51.(9+N)`). **This is why a reservation gives stable identity here** —
    the MAC is launcher-assigned per slot, not random, contradicting the earlier
    "reservations don't give stable identity" worry below; that caveat applies only
    to an _unpinned_ tier beyond the 16 named slots. The registry still owns the
    `.internal` DNS; bt8gw just supplies the matching address.
  - **DHCP for any _unpinned_ tier** — VLAN 51's other tiers don't use it (LB VIPs
    come from MetalLB, flannel pods use flannel IPAM, erebonia's egress is static).
    DHCP matters again only if unpinned ephemeral VMs run _beyond_ the 16 slots —
    those would get random MACs, so reservations wouldn't help (use Whereabouts or
    cloud-init static); if that tier ever needs **names**, prefer the kresd
    programmatic-DNS direction (above) over bt8gw DHCP→DNS.
  - **Whereabouts** keeps allocation in-cluster (no bt8gw lease churn, no
    coupling to a hand-managed non-flake device); **bt8gw DHCP** reuses existing
    infra but the dynamic pool must be hand-carved clear of the static band / LB
    pool / erebonia egress, and bt8gw must remain the _sole_ DHCP server on the
    VLAN-51 L2 (a multus `dhcp`-IPAM VM is a client; don't also run an in-cluster
    DHCP server).

  **Leaning:** default named workloads to static+registry; pick Whereabouts for
  any ephemeral pool unless reusing bt8gw DHCP is clearly simpler at the time.

- **Do the dev-machine VMs need to roam?** — the axis that decides whether
  future state B is ever needed. Current assumption: **no** (pets), so the
  non-invasive plan stands and Kube-OVN stays deferred.
- **LB mode** — start L2; revisit BGP only if the ingress funnel bites.
