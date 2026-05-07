# Dual-Gateway + APP VLAN Migration Plan

**Status:** Drafted (not started)
**Last updated:** 2026-05-07 (revised: added security verification, layered —
Phase 0a gains three small universal eval-time assertions in
`modules/router6/default.nix` (WAN inputRules accept WG only; no DHCP server
on NAT interfaces; `icmpEcho = "disable"` on NAT zones) plus a small generic
module-level VM test (`router6-listening-sockets`) closing the wildcard-bind
gap in the existing suite; Phase 0b gains a post-cutover external scan as a
required step before declaring Phase 0 done; new "External security scan"
runbook (Reference E) documents the off-network scan procedure as the
empirical thebeyond-specific audit; Phase 3 re-runs the runbook (largest
zone-topology change). Deliberately omitted: a fourth WG-port-uniqueness
assertion (runtime service-start failure is loud enough), a UDP-stealth VM
test (assertion (a) catches the regression class structurally; the runbook
covers the residual gap empirically), and trust-level taxonomies in router6
(project-policy layering — would live in a project-side wrapper if pursued
later).

Earlier: simplification pass — Phase 6 folded into Phase 5
(DMZ renumber happens once the only remaining DMZ residents are langport/trista);
`router6.routes` option introduction moved from Phase 1 to Phase 2 (paired with first
use); pre-flight `switchVlans` cleanup folded into Phase 0a step 1; per-prefix-length
test committed to Phase 0a with a synthetic fixture; assorted optional/conditional
hedges resolved.

Earlier: Phase 0 split into 0a/0b; transit→hostile forward rules to permit HOME→IoT
(HA) and the wider trust-boundary policy; ULA-only runbook fixes; DMZ exception route
on BT8-gw during the override window; kresd transit binding via input rules; NAT-rule
verification resolved; arseille deferred — `netmgmt` zone stays as the architectural
placeholder, with the existing OpenWRT homelab L2 switch documented as its first
consumer in a follow-up plan.)
**Related:**
- `done/secure-mgmt-vlan-plan.md` — established INFRA/MGMT split this plan extends
- `done/openwrt-python-builder.md` — Image Builder pipeline this plan adds device types to

## Background

`thebeyond` hardware is in hand and ready to deploy as the primary gateway. Two
requirements have shifted since `thebeyond`'s initial spec:

1. **Two physical gateways.** `thebeyond` lives next to the modem; the homelab
   stays in the office. Inter-VLAN traffic that currently round-trips through the
   mesh is unacceptable, so one of the office-side BT8 devices must also act as a
   gateway. Only `thebeyond` does NAT (one egress point).
2. **APP zone, distinct from DMZ.** APP hosts inherit the DMZ host-hardening
   posture — host-level input firewalls and host-level egress filtering
   (`mkEgressFilter` from `lib.common.nftables`) — so their security
   doesn't depend solely on BT8-gateway's fw4. DMZ keeps strict isolation (forced through
   `thebeyond`). APP is a new zone for internal-but-not-trusted services that
   *don't* need to round-trip through the modem closet. APP is "DMZ-shaped" in
   posture but locally routed by the office-side gateway.

Image deployment to the BT8 fleet and `thebeyond` will eventually run via
deploy-rs from a dedicated pusher host (separate from the saint-arkh job
runners). That host's zone placement and forwarding rules are out of scope
for this plan — they'll be specified when the pusher plan lands. Manual
deploys via the operator's workstation handle Phases 0–4.

## Goals

- Get `thebeyond` deployed as the primary gateway alongside a working
  office-side gateway, in an order that keeps the network functional at every
  step.
- Define and provision the APP zone and the cross-gateway transit zone.
- Prove out the BT8-gateway role manually first; codify in the Image Builder
  pipeline only after we know what's actually needed.
- Document the BT8 "dumb AP" / 802.11s wireless bridge config so we have a
  fat-pipe link from `thebeyond` into the office mesh.

## Non-goals

- Reflashing/decommissioning the last remaining E8450 mesh AP. Four of five
  have already been pulled in advance of this plan; the final one is
  optional and tracked separately.
- Decommissioning `glorious`'s role beyond ADU's L3 gateway. ADU's
  L3 gateway moves to `thebeyond` as part of the gateway split (along
  with the other untrusted-family zones); any remaining glorious-side
  responsibilities are out of scope here.
- Headscale, IPv6 GUA stable ingress, and other in-flight zone work
  (covered by their own plans). Where they touch the same files, this plan
  notes it but does not subsume them.

## Design principle: trust-boundary north/south, intra-trusted east/west

The two gateways have distinct, complementary roles. Read "north/south"
broadly as **any trust-boundary crossing** — not just the WAN edge:

- **`thebeyond` is the trust-boundary chokepoint (north/south).** All
  traffic that crosses a trust boundary terminates here: WAN ingress/
  egress (NAT, ISP-facing), trusted ↔ hostile (HOME → IoT, etc.),
  wireguard concentration (`media`, future `wg-iot`), and the
  high-trust core itself (`network` MGMT VLAN, where router/switch
  admin and DNS infrastructure live).
- **`BT8-gateway` is the intra-trusted east/west router.** It owns
  L3 termination for the trusted office zones (`management`/INFRA,
  `trusted`/HOME, `lab`, `app`) — flows that don't cross a trust
  boundary, just zones-of-similar-trust talking to each other.
- **The transit VLAN** is plumbing between the two roles, not a zone
  in its own right.

Practical implication for placement decisions: when adding a new VLAN
or service, ask "does traffic to/from this cross a trust boundary?"
If yes, it lands on `thebeyond`. If it's intra-trusted east/west, it
lands on `BT8-gateway`. Hostile zones (`untrusted`, `iot`, `game`,
`adu`, `dmz`) are "north of trusted" in the classic enterprise sense
even though they're physically internal — same as how a DMZ has
always been treated.

`BT8-gateway` is hermetically east/west: it holds *no* L3 interface
on `network` or any other thebeyond-terminated zone. Admin SSH lands
on its transit address (`10.255.255.2`), and it queries
`thebeyond`'s local resolver at `10.255.255.1` rather than reaching
into `network` for phantasma directly. The cost is that emergency
admin access depends on the transit link being healthy — a USB
serial console on the BT8-gateway is the recovery path of last
resort, and worth keeping pre-staged. The benefit is that an
attacker who compromises BT8-gateway has no L2 foothold in the
high-trust plane.

## Network-device placement: zero-or-one mesh hop

The trust-boundary principle decides which gateway terminates *user-facing*
zones (DMZ, hostile zones to thebeyond; trusted office zones to BT8-gw).
A separate question is where the *infrastructure devices themselves*
(network gear: switches, dumb APs, mesh bridges) hold their management
addresses. The single-mesh-traversal invariant gives a clean rule:

> A network device's management VLAN should terminate at the gateway it
> is **physically closest to** — measured in mesh hops, not in trust
> level. Wired-to-X means terminate at X (zero mesh hops). Mesh-resident
> means terminate at whichever gateway is one mesh hop away.

This is independent from trust-boundary placement: data VLANs follow the
trust-boundary principle (a hostile SSID's L3 still terminates at
`thebeyond` even when broadcast from a BT8-gw-side AP), while the AP's
*own* management address follows the placement principle (one mesh hop
toward `BT8-bridge` and out to `thebeyond` is shorter than one toward
`BT8-gw` and then *another* mesh hop onward).

Worked examples:

| Device                     | Physical attachment            | Mgmt VLAN          | Mesh hops to its gateway |
|----------------------------|--------------------------------|--------------------|--------------------------|
| `BT8-bridge`               | wired to `thebeyond`           | `network` / 10     | 0                        |
| Office BT8 dumb APs        | 802.11s mesh (office side)     | `network` / 10     | 1 (via mesh → BT8-bridge → thebeyond) |
| Future wired-to-BT8-gw gear | wired to `BT8-gateway`        | `netmgmt` / 12     | 0                        |
| `BT8-gateway` (admin SSH)  | wired to office mesh + transit | `transit` / 99     | 0 (transit IP)           |

Counterexamples that would violate the invariant:

- Dumb AP mgmt on `netmgmt` / 12 → AP needs to talk to phantasma, ends
  up `AP → mesh → BT8-gw L3 → mesh → BT8-bridge → thebeyond` = **2 mesh
  hops**.
- L2 switch mgmt on `network` / 10 → admin from a BT8-gw-side workstation
  goes `host → BT8-gw → transit → thebeyond → BT8-bridge → mesh → BT8-gw
  → switch` = **2 mesh hops** (because BT8-gw can't route VLAN 10 itself,
  so it must hairpin via thebeyond).

Practical consequence: VLAN 10 must be carried at L2 across the batman
fabric (mesh + wired BT8-bridge↔thebeyond hop) so the dumb APs can
participate, but BT8-gateway holds *no L3* on it — VLAN 10 joins the
hostile-zone passthrough list on BT8-gw (bridge membership only,
`proto 'none'`, no fw4 zone). Hermetic east/west isolation is an L3
claim and is preserved.

## Mesh L2 layer: `batman-adv` over `802.11s` (and over wire to `thebeyond`)

The wireless underlay is `802.11s` (it carries the encrypted mesh frames),
but `batman-adv` runs on top to provide a flat, VLAN-aware L2 across the
mesh. This is the same pattern `thebeyond` currently runs, with one
simplification described below.

The reason `batman-adv` matters here: VLANs need to be carried *through*
the mesh so that GUEST/IOT/GAME SSIDs on every BT8 actually deliver
frames onto the right VLAN. `802.11s` alone does not preserve 802.1Q tags
across mesh hops in a clean way; `batman-adv` does.

After this plan ships:
- `thebeyond` keeps `batman-adv`, but its `bat0` hard interface is a
  *wired* link to `BT8-bridge` rather than a wireless one. `bond0` is
  gone (single NIC) and per-VLAN bridges have only `bat0.<tag>` members
  — the wired link is now batman-encapsulated, not a plain VLAN trunk.
- Every BT8 (bridge, gateway, mesh APs) runs `batman-adv` with `bat0` as
  its mesh device. `BT8-bridge` has *two* hard interfaces: the wired
  link to `thebeyond` and `mesh0` (802.11s). Other BT8s have only `mesh0`.
- Per-VLAN bridges on each BT8 join `bat0.<tag>` (mesh-or-wired side via
  batman) and `lanN.<tag>` (wired-client side, where present).

Trade-offs of keeping `batman-adv` on `thebeyond`:
- **+** No major rewrite of `mkVlanBridge` — drops the `bond0Vlans` half
  but otherwise stays the same shape.
- **+** `thebeyond` retains full mesh visibility (`batctl o`, `batctl n`)
  so office-side mesh issues are diagnosable from the modem closet.
- **−** ~25 bytes of batman encapsulation overhead on the wired hop.
  Already covered by the existing `mtu = 1536` on the batman-side
  interfaces.
- **−** The wired link is no longer a plain VLAN trunk; anything that
  speaks to `BT8-bridge` over that wire must speak batman. Not relevant
  in this topology, but worth noting if a future device wants to plug
  into it.

## Architecture

### Physical topology after migration

```
                            ┌───────────────┐
                  ─── WAN ──┤   thebeyond   │  (modem closet — primary gateway)
                            │  (NAT, DMZ,   │
                            │   network,    │  bat0 (wired hard interface
                            │   transit)    │   to BT8-bridge — no bond0)
                            └──────┬────────┘
                                   │ single wire — batman-encapsulated
                                   │
                            ┌──────┴──────────┐
                            │   BT8-bridge    │  (modem closet — "dumb AP")
                            │  batman-adv:    │
                            │  wired hardif + │
                            │  802.11s mesh   │
                            └──────┬──────────┘
                                   │ 802.11s mesh ("fat pipe")
                                   │
                            ┌──────┴──────────┐
                            │  BT8-gateway    │  (office — secondary gateway)
                            │  L3: app, mgmt, │
                            │      netmgmt,   │  + 802.11s mesh node
                            │      trusted,   │  + AP radios for ALL VLANs
                            │      lab        │    (incl. iot/game/guest —
                            │  L2 only:       │    SSIDs broadcast here, but
                            │   iot/game/     │    L3 lives on thebeyond)
                            │   guest/adu/    │
                            │   network       │  network/10 is L2-passthrough
                            │                 │    so dumb APs reach thebeyond
                            └──┬──────────────┘
                               │ wired (trunk, plain 802.1Q — not batman)
                               │
                              homelab gear (wired trunk)

Only BT8-bridge and BT8-gateway are configured by this plan; both are
assumed to be in hand.
```

`thebeyond` connects to `BT8-bridge` over a single wired link that acts
as a `batman-adv` hard interface (no bond, no plain VLAN trunk). All
VLANs are carried as `bat0.<tag>` and merged into per-VLAN bridges on
the `thebeyond` side.

`BT8-bridge` runs OpenWrt as a flat L2 bridge across two `batman-adv`
hard interfaces — the wired link to `thebeyond` and `mesh0` (802.11s).
It has no IP addresses except a single management address on `network`
VLAN. It exists only to fan the batman fabric out to the office mesh.

`BT8-gateway` runs OpenWrt with proper firewall zones, DHCP, and routing
for the office-side VLANs. It is *also* a mesh node (so the office
wireless mesh isn't dependent on a separate device for its uplink). Its
wired side toward downstream homelab gear is a plain 802.1Q trunk —
that gear does not speak batman. The batman fabric terminates at the
per-VLAN bridges inside `BT8-gateway`.

### Routing model

- **NAT**: only on `thebeyond` (single egress point).
- **Default route**:
  - `thebeyond`: out the WAN.
  - `BT8-gateway`: out the **transit** VLAN to `thebeyond`'s transit address
    (`10.255.255.1`, `fdc6:55f2:0a5e:ffff::1`).
- **Static routes on `thebeyond`** (single entry per protocol thanks to the
  per-gateway address-space split):
  - IPv4: `10.97.0.0/16 via 10.255.255.2 dev brTRANSIT`
  - IPv6: `fdc6:55f2:0a5e:1000::/52 via fdc6:55f2:0a5e:ffff::2 dev brTRANSIT`
- **Static routes on `BT8-gateway`**: default route covers both DMZ and
  `network` (and anything else thebeyond-side), since both live in
  thebeyond's `10.91.0.0/16` / `fdc6:55f2:0a5e:0000::/52` slice.
- **L2-only passthrough on `BT8-gateway`**: every hostile-zone VLAN
  (`untrusted`/30, `iot`/40, `game`/41, `adu`/31), DMZ (100), and
  `network` (10) are bridged through `BT8-gateway` with no IP — frames
  cross batman to `thebeyond` where the L3 gateway and firewall live.
  SSIDs for the hostile zones are still broadcast from BT8 APs
  (BT8-gateway and any other mesh AP), but client traffic terminates
  on `thebeyond`. `network`/10 is carried only so the office-side dumb
  APs can reach their L3 home (`thebeyond`); see the
  [network-device placement](#network-device-placement-zero-or-one-mesh-hop)
  section. This is the hostile-zone convergence model for the data
  VLANs — see resolved decision below.
- **Transit VLAN passes through `BT8-bridge`**: like every other VLAN,
  the transit VLAN (99) is carried as `bat0.99` across the batman
  fabric. `BT8-bridge` participates in transit only as a passthrough
  L2 bridge with no IP on it; the actual peers are `thebeyond`
  (`10.255.255.1`) and `BT8-gateway` (`10.255.255.2`).
- **All cross-gateway flows are symmetric via transit.** `BT8-gateway`
  has no L3 interface on `network` (or any other thebeyond-terminated
  zone), so any flow between BT8-side trusted zones and thebeyond-side
  zones traverses the transit VLAN in both directions. Example: a DNS
  query from a HOME host to phantasma takes
  `HOME-host → BT8-gateway → transit → thebeyond → brMGMT → phantasma`
  on the forward direction, and the mirror path on the reverse. Both
  gateways see both directions of the flow, so conntrack and zone
  forwards match cleanly without the asymmetric-routing edge cases
  the prior plan worked around.
- **BT8-gateway's own DNS / NTP point at thebeyond's transit IP.**
  BT8-gateway does not reach into the `network` segment; its dnsmasq
  upstream is `10.255.255.1` (thebeyond's local kresd, which forwards
  to phantasma) and its NTP source is the same. This avoids the need
  for a `transit → network` forward rule scoped to BT8-gateway as a
  source.

### IPv6

**Baseline: ULA-only internal IPv6, IPv4 NAT for all WAN.** The ISP is
known to delegate only `/64` today (verified off-codebase by the
operator against the existing gateway), and a single `/64` cannot be
subdivided for SLAAC across multiple VLANs. Most cable ISPs key the
delegation on the cable modem / account, not on the LAN-side device,
so swapping in `thebeyond` (with a different WAN MAC) is unlikely to
change the size. Plan accordingly.

Concrete shape:

- **WAN**: request PD for visibility (`ipv6PrefixDelegation.enable =
  true` with `prefixLength = 60` as a polite hint). Whatever lands,
  lands; if it's `/64`, stamp it on the WAN interface only and don't
  attempt to subdivide.
- **Internal**: ULA-only on every VLAN — what the registry generates
  from `ulaPrefix` + `vlanHex`. Both `thebeyond` and `BT8-gateway`
  stamp ULA addresses on their owned VLANs.
- **`thebeyond`**: no DHCPv6-PD *server* on transit, no sub-prefix
  delegation to BT8-gateway.
- **`BT8-gateway`**: no `transit6` DHCPv6 client interface. `odhcpd`
  advertises RAs and serves DHCPv6 for ULA prefixes only — no GUA
  per-VLAN. Skip `option ip6assign '64'` on per-VLAN bridges.
- **Internet egress**: IPv4 NAT only. Outbound IPv6-to-internet from
  internal hosts does not work; happy-eyeballs falls back to IPv4 for
  dual-stacked services. IPv6-only services break (rare in practice).
- **Inbound IPv6**: deferred. The `ipv6-gua-stable-ingress` plan waits
  for a real PD or pivots to IPv4-only inbound.

This posture composes cleanly with the dual-gateway IPv4 plan —
nothing in Phases 1–5 depends on GUA.

### IPv6 — if the ISP ever enlarges the delegation

If the ISP later provisions a `/60` or larger (operator request, plan
change, etc.), the original "primary path" becomes available:

- `thebeyond` retains DHCPv6-PD client toward ISP.
- `thebeyond` runs DHCPv6-PD *server* on the transit VLAN, delegating
  a sub-prefix to `BT8-gateway` so it can carve `/64`s for its VLANs.
- `BT8-gateway` runs `odhcpd` advertising RAs and per-VLAN DHCPv6 with
  GUA.
- ULA addressing stays alongside GUA (dual-stack internal).

Switching from ULA-only to GUA-enabled is additive on top of the
baseline above — re-add the PD server on transit, the `transit6`
client on BT8-gateway, and `option ip6assign '64'` on each VLAN
bridge. None of this is on the critical path for the dual-gateway
IPv4 work.

### Firewall split

We accept that the firewall responsibility is now split across two devices.
`thebeyond` (NixOS, `router6` module, nftables) owns its half; `BT8-gateway`
(OpenWrt, fw4) owns the other half. The two zone models are designed to
mirror each other in name and intent, but they are not auto-derived from a
single source — yet (Phase 4 introduces partial codification through the
Image Builder).

| Zone           | Owner          | DHCP                | NAT |
|----------------|----------------|---------------------|-----|
| `external`     | `thebeyond`    | (DHCP client)       | yes |
| `network`      | `thebeyond`    | static-only (no DHCP) | no |
| `dmz`          | `thebeyond`    | `thebeyond` Kea     | no  |
| `transit`      | `thebeyond`    | static `/30`        | no  |
| `ba-tunnel`    | `thebeyond`    | wireguard           | yes (masq) |
| `app` *(new)*  | `BT8-gateway`  | dnsmasq + odhcpd    | no  |
| `management`   | `BT8-gateway`  | dnsmasq + odhcpd    | no  |
| `netmgmt` *(new)* | `BT8-gateway` | dnsmasq + odhcpd    | no  |
| `trusted`      | `BT8-gateway`  | dnsmasq + odhcpd    | no  |
| `lab`          | `BT8-gateway`  | dnsmasq + odhcpd    | no  |
| `untrusted`*   | `thebeyond`    | `thebeyond` Kea     | no  |
| `media`        | `thebeyond`    | (wg-keyed only)     | no  |

(BT8-gateway DHCP is dnsmasq for v4 + odhcpd for v6/RA, configured under
the unified OpenWrt `/etc/config/dhcp` UCI tree.)

\* `untrusted` here covers GUEST, IOT, GAME, and ADU. All four converge on
`thebeyond` per the hostile-zone convergence resolved decision below;
BT8-gateway passes their VLAN frames as L2-only batman traffic without
terminating L3 on those bridges. ADU's L3 gateway moves from `glorious`
to `thebeyond`; any remaining glorious-specific behavior is out of scope.

## Network registry changes

### Per-gateway address-space split (foundational)

Each zone declares which gateway owns it; the registry derives both IPv4 and
IPv6 prefixes from a small `gateways` table rather than from a single global
prefix. New top-level constants in `lib/common/data/network.nix`:

```nix
ulaPrefix = "fdc6:55f2:0a5e";       # /48, unchanged

gateways = {
  thebeyond = { prefix4 = "10.91"; ulaGroup = 0; };  # /16 + /52 slice 0
  bt8gw     = { prefix4 = "10.97"; ulaGroup = 1; };  # /16 + /52 slice 1
};
```

Each non-transit zone gets a `gateway = "thebeyond"` or `gateway = "bt8gw"`
field. Transit is special-cased (its own prefix, neither gateway).

Subnet derivation per zone:

```nix
# Helper: encode the gateway slice + VLAN ID as a 16-bit ULA subnet ID.
ulaSubnetHex = group: vlanId:
  lib.fixedWidthString 4 "0" (lib.toLower (lib.toHexString (group * 4096 + vlanId)));

# Within rawNetworks enrichment:
networks = lib.mapAttrs (_: net: let
  gw = gateways.${net.gateway};
  prefix4 = net.prefix4 or "${gw.prefix4}.${toString net.vlanId}";
  prefix6 = net.prefix6 or "${ulaPrefix}:${ulaSubnetHex gw.ulaGroup net.vlanId}";
  prefixLength4 = net.prefixLength4 or 24;
  prefixLength6 = net.prefixLength6 or 64;
in
  net // {
    inherit prefix4 prefix6 prefixLength4 prefixLength6;
    subnet4 = "${prefix4}.0/${toString prefixLength4}";
    subnet6 = "${prefix6}::/${toString prefixLength6}";
    gateway4 = "${prefix4}.1";
    gateway6 = "${prefix6}::1";
  })
  rawNetworks;
```

The `prefix4` / `prefix6` overrides exist so transit can declare its own
prefix without going through the gateway table; regular zones leave them
unset and inherit from their gateway.

`mkHost` similarly takes the network record (or its `prefix4` / `prefix6`)
so host addresses are `${prefix4}.${hostId}` and
`${prefix6}::${hostHex hostId}`. The `hostRangeCheck` validation
becomes prefix-length-aware: `hostId` must fit in
`2^(32 - prefixLength4) - 2`.

Concrete addresses produced by this scheme:

| Zone        | VLAN | Gateway   | IPv4              | ULA `/64`                       |
|-------------|------|-----------|-------------------|---------------------------------|
| network     | 10   | thebeyond | `10.91.10.0/24`   | `fdc6:55f2:0a5e:000a::/64`      |
| dmz         | 100  | thebeyond | `10.91.100.0/24`  | `fdc6:55f2:0a5e:0064::/64`      |
| management  | 11   | bt8gw     | `10.97.11.0/24`   | `fdc6:55f2:0a5e:100b::/64`      |
| netmgmt     | 12   | bt8gw     | `10.97.12.0/24`   | `fdc6:55f2:0a5e:100c::/64`      |
| trusted     | 20   | bt8gw     | `10.97.20.0/24`   | `fdc6:55f2:0a5e:1014::/64`      |
| lab         | 21   | bt8gw     | `10.97.21.0/24`   | `fdc6:55f2:0a5e:1015::/64`      |
| untrusted   | 30   | thebeyond | `10.91.30.0/24`   | `fdc6:55f2:0a5e:001e::/64`      |
| iot         | 40   | thebeyond | `10.91.40.0/24`   | `fdc6:55f2:0a5e:0028::/64`      |
| game        | 41   | thebeyond | `10.91.41.0/24`   | `fdc6:55f2:0a5e:0029::/64`      |
| app         | 50   | bt8gw     | `10.97.50.0/24`   | `fdc6:55f2:0a5e:1032::/64`      |
| adu         | 31   | thebeyond | `10.91.31.0/24`   | `fdc6:55f2:0a5e:001f::/64`      |
| transit     | 99   | (special) | `10.255.255.0/30` | `fdc6:55f2:0a5e:ffff::/64`      |

### Move phantasma from `management` (INFRA) to `network` (MGMT)

`phantasma` is the recursive DNS resolver and is consumed by every router on
the network — both `thebeyond` (`router6.dns.upstream`) and `BT8-gateway`
(dnsmasq forwarder). Routing depends on DNS, and routing infrastructure
lives on VLAN 10 (`network` zone), so phantasma belongs there too. Keeping it
on INFRA created a Phase-3 hairpin where `thebeyond`'s own DNS queries had to
traverse `transit → BT8-gateway → mesh` to reach a microVM physically hosted
on `thebeyond` itself.

After the move:
- `thebeyond` reaches phantasma directly across `brMGMT` (`10.91.10.1/24`
  stays on `thebeyond` per resolved decision: `network` gateway location).
- `BT8-gateway` reaches phantasma via the transit link by querying
  thebeyond's local resolver at `10.255.255.1` — *not* by holding an
  L3 address on `network`. BT8-gateway has no foot in the high-trust
  plane (see resolved decision on hard east/west isolation below).
- The microvm bridge in `hosts/thebeyond/router.nix`
  (`systemd.network.networks."10-vm-infra"`) needs to retarget to `brMGMT`
  for phantasma's tap; INFRA-resident microvms (none today, but the
  pattern remains) keep targeting `brINFRA`. A pure rename or a per-VM
  match is fine — operator's call.

Registry change: in `lib/common/data/network.nix`, move `phantasma` from
`management.hosts` to `network.hosts` and re-number it to host ID `10`
(see [Network host-ID convention](#network-host-id-convention) below for
why phantasma lands at `.10` rather than `.2`). Phantasma's IPv4 changes
(`10.97.11.2` → `10.91.10.10`) — both because the VLAN moves *and* because
`network` is in thebeyond's `10.91` slice. Its ULA changes too (now
`fdc6:55f2:0a5e:000a::a` — VLAN 10 in thebeyond's group-0 slice, host ID
10). DNS records, `/etc/hosts`, and egress rules regenerate from the
registry, so no other call-site changes are required.

### Network host-ID convention

`network` is the only zone that mixes transport infrastructure (gateways,
wireless-bridge mgmt, future managed-switch mgmt IPs) with a service
(`phantasma`). To keep that distinction legible in the registry, host IDs
1–9 are reserved for transport and 10+ for services:

```nix
network.hosts = {
  thebeyond  = 1;    # primary gateway (only L3 host on `network`)
  bt8bridge  = 4;    # wireless-bridge mgmt (wired to thebeyond — 0 mesh hops)
  # office-side dumb APs land in 5–9 (mesh-resident network gear,
  # placed here per the placement principle: 1 mesh hop to thebeyond
  # via BT8-bridge, vs. 2 if they lived on netmgmt/12).
  # 2, 3 reserved for future transport.
  phantasma  = 10;
};
```

`bt8gw` is deliberately *absent* from `network.hosts`: BT8-gateway has
no L3 interface on `network` (hermetic east/west isolation). Its
admin-reachable address is its transit IP (`10.255.255.2`), not a
network-VLAN address.

This 1–9 / 10+ convention is `network`-specific. Other zones either
have no transport role (DMZ, APP, HOME, etc.) or are already constrained
(`transit` is `/30`), so the reservation only applies here. `netmgmt`/12
has only network-gear residents by definition, so no transport/service
split is needed.

### New zones

Three new zones in `lib/common/data/network.nix`:

```nix
app = {
  vlanId = 50;            # picked: between LAB (21) and DMZ (100)
  gateway = "bt8gw";
  hosts = {};             # populated as services migrate
};
netmgmt = {
  vlanId = 12;            # BT8-gw-side parallel of thebeyond's network/10
  gateway = "bt8gw";
  hosts = {};             # populated when wired-to-BT8-gw network gear
                          # (managed switches, PDUs, BMC) lands here
};
transit = {
  vlanId = 99;
  # Special-cased: third address space, neither gateway. Both prefix4
  # and prefix6 overridden directly rather than derived from the
  # gateway table.
  prefix4 = "10.255.255";
  prefix6 = "${ulaPrefix}:ffff";
  prefixLength4 = 30;
  hosts = {
    thebeyond = 1;     # 10.255.255.1, fdc6:55f2:0a5e:ffff::1
    bt8gw     = 2;     # 10.255.255.2, fdc6:55f2:0a5e:ffff::2
  };
};
```

`netmgmt` exists for the same reason as `network`/VLAN 10: a locked-down
zone for *network gear* management, kept separate from VM hosts and
NAS (`management`/VLAN 11). Both gateways have one — they live on
opposite sides because the right placement for any given device depends
on which gateway it's physically closest to (see the
[network-device placement principle](#network-device-placement-zero-or-one-mesh-hop)
section). `netmgmt` is BT8-gw-side; `network` is thebeyond-side.

Existing zones gain an explicit `gateway` field. The split moves
`network` and `dmz` into `thebeyond`'s slice, everything else into
`bt8gw`'s slice:

```nix
# All hostile/untrusted zones converge on thebeyond — see resolved decision
# on hostile-zone convergence below. BT8-gateway only terminates the
# trusted "office work" zones; iot/untrusted/game pass through it as
# L2-only batman frames.
network    = { vlanId = 10;  gateway = "thebeyond"; hosts = { ... }; };
dmz        = { vlanId = 100; gateway = "thebeyond"; hosts = { ... }; };
untrusted  = { vlanId = 30;  gateway = "thebeyond"; hosts = { ... }; };
adu        = { vlanId = 31;  gateway = "thebeyond"; hosts = { ... }; };
iot        = { vlanId = 40;  gateway = "thebeyond"; hosts = { ... }; };
game       = { vlanId = 41;  gateway = "thebeyond"; hosts = { ... }; };

management = { vlanId = 11;  gateway = "bt8gw"; hosts = { ... }; };
netmgmt    = { vlanId = 12;  gateway = "bt8gw"; hosts = { ... }; };
trusted    = { vlanId = 20;  gateway = "bt8gw"; hosts = { ... }; };
lab        = { vlanId = 21;  gateway = "bt8gw"; hosts = { ... }; };
app        = { vlanId = 50;  gateway = "bt8gw"; hosts = { ... }; };
```

Because `BT8-gateway` holds `.1` directly in its own slice, no `bt8gw =
2` transition host-IDs are needed — there's no "shared `.1`" cutover
flap to step around. The only `bt8gw` entry that remains is:

- `transit.hosts.bt8gw = 2` — BT8-gateway's transit interface, the
  *only* L3 address it holds outside its own `10.97.0.0/16` slice.
  Admin SSH targets this address; there is no `network.hosts.bt8gw`
  entry by design (hermetic east/west isolation — BT8-gateway has
  no foot in the high-trust plane).

`transit` gets its own zone in both router6 and BT8 fw4. On `thebeyond`,
transit is the entry point for *all* office-side traffic destined for
`thebeyond`-resident zones (DMZ, external/NAT, ba-tunnel) — so its
`accessTo` is non-empty (see zone definitions below). Source-zone
attribution is lost across the gateway split: BT8-gateway's fw4 is the
source-zone enforcer, transit's `accessTo` gates by destination only.

### Zone wiring

In `modules/router6/...` (`thebeyond`):

```nix
router6.zones = {
  # ... most existing zones unchanged ...

  network = {
    # Was: locked-down "AP/switch lockdown" zone (NTP only, no lateral).
    # Now: "router-adjacent infrastructure" — phantasma (recursive DNS
    # resolver) lives here. Two distinct DNS paths to support:
    #   1. thebeyond's local kresd → phantasma (recursive upstream): an
    #      input-chain flow on `network` itself, since both endpoints
    #      sit on `brMGMT`. The `udp/tcp dport 53` rules below handle
    #      this.
    #   2. BT8-gw-side clients → DNS: they target `10.255.255.1`
    #      (thebeyond's kresd via transit), which forwards to phantasma.
    #      This path is `transit input → kresd → network output to
    #      phantasma`, NOT a network-zone forward, so no
    #      `accessTo = [ "transit" ]` is needed here.
    #
    # `accessTo` is empty: phantasma does not initiate outbound to other
    # internal zones; only the kresd-on-thebeyond path does, and that
    # is router-local (output, not forward).
    icmpEcho = "enable";
    accessTo = [];
    inputRules = [
      { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
      # DNS to phantasma from thebeyond's local kresd (same L2 segment).
      { udp.dport = 53; verdict = "accept"; comment = "DNS"; }
      { tcp.dport = 53; verdict = "accept"; comment = "DNS (TCP)"; }
    ];
    # No forwardRules.external — phantasma's upstream queries are sent
    # by thebeyond's kresd, not by phantasma directly outbound, so the
    # `network → external` path doesn't need to be opened up.
  };

  transit = {
    icmpEcho = "enable";   # for traceroute/diagnostics
    # transit forwards office-side traffic into thebeyond-resident zones.
    # Source attribution is lost across the gateway split — BT8-gateway's
    # fw4 enforces source policy; transit gates by destination + source
    # subnet/host only (no zone-tagged saddr available).
    accessTo = [ "external" "ba-tunnel" ];   # dmz + hostile zones handled
                                              # via forwardRules below
    # DNS input rules on transit serve a dual purpose: (1) BT8-gateway and
    # other BT8-gw-side network devices forward DNS queries to
    # `10.255.255.1` (thebeyond's local kresd). (2) The router6 module
    # auto-binds kresd to any interface in a zone whose `inputRules` allow
    # DNS (`dnsInterfaces` in `modules/router6/lib.nix`), so adding these
    # rules implicitly listens kresd on `brTRANSIT` — no separate listen
    # configuration needed.
    inputRules = [
      { udp.dport = 53; limit = "100/second"; verdict = "accept"; comment = "DNS"; }
      { tcp.dport = 53; limit = "100/second"; verdict = "accept"; comment = "DNS over TCP"; }
      { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
    ];

    # Explicit transit→dmz rules. Mirrors the cross-zone DMZ flows that
    # used to be enforced inside thebeyond before office-side gateways
    # moved to BT8-gateway. Defense-in-depth: we don't trust BT8-gateway
    # implicitly with any-host:any-port DMZ ingress.
    #
    # ba-tunnel and media zones still live on thebeyond, so their
    # existing forwardRules.dmz (wg-ba → trista:22, wg-media → oracion:443)
    # stay in place unchanged on those zones — no transit-side mirror needed.
    forwardRules.dmz =
      # lab → dmz (broad) — mirrors the current `lab.accessTo = [..."dmz"...]`
      # permissive forward. Source-restricted to the lab subnet so a
      # compromised BT8-gateway can't impersonate other zones into DMZ.
      (ds {
        saddr = "10.97.21.0/24";   # lab subnet
        verdict = "accept";
        comment = "lab -> dmz (any) [via BT8-gateway]";
      })
      # management → dmz:9100 (Prometheus node_exporter scrape from tharbad).
      # Mirrors the current `management.forwardRules.dmz` rule scoped to tharbad.
      ++ (ds {
        saddr = tharbad;
        tcp.dport = 9100;
        verdict = "accept";
        comment = "tharbad -> dmz (node_exporter) [via BT8-gateway]";
      });
    # Note: app → dmz forwards (e.g., saint-arkh → DMZ services) are
    # configured on BT8-gateway directly if/when needed — saint-arkh
    # currently lives in DMZ, and Phase 5 may move it to APP. If the
    # destination remains in DMZ and the source moves to APP, the path
    # is APP → BT8-gateway → transit → thebeyond → DMZ, requiring a new
    # transit→dmz rule scoped to the saint-arkh source IP. Add when the
    # move happens.

    # Trusted-side → hostile-zone forwards. With hostile zones converged
    # on `thebeyond`, BT8-gw-side trusted hosts that need to reach an
    # IoT/GUEST/GAME endpoint go through transit. Source-restrict to the
    # exact subnet on the BT8-gw side so a compromised BT8-gw can't
    # impersonate a different zone. (Source-zone attribution is lost
    # across the gateway split — IP subnet is the strongest constraint
    # available here.)
    #
    # `iot`: HOME → IoT for Home Assistant. A future HA instance lands on
    # the IoT VLAN; HOME hosts (humans) need to reach its web UI/API.
    # Scoped broadly to the trusted subnet today; tighten to the HA host
    # IP and ports (8123 + any companion ports) when HA is deployed and
    # has a registry entry.
    forwardRules.iot = (ds {
      saddr = "10.97.20.0/24";   # trusted/HOME subnet
      verdict = "accept";
      comment = "trusted -> iot (Home Assistant access) [via BT8-gateway]";
    });
    # `untrusted` (GUEST/30): mirrors the current `trusted.accessTo`
    # which already permits trusted → untrusted. Path is now via transit.
    forwardRules.untrusted = (ds {
      saddr = "10.97.20.0/24";
      verdict = "accept";
      comment = "trusted -> untrusted (any) [via BT8-gateway]";
    });
    # `game` (41): no current consumers; add when a use case appears.
    # `adu` (31): no trusted-side initiators today — glorious's role is
    # being narrowed and ADU is an isolation zone.
  };
};
```

**NAT verification (resolved).** `transit → external` relies on the existing
masquerade rule in `modules/router6/firewall.nix` matching on egress
interface only (`oifname = natInterfaces`, line ~437) with no source-zone
gate. Confirmed by code inspection: any flow forwarded out a NAT-flagged
WAN interface is masqueraded regardless of source zone, so adding
`transit` to the source mix needs no firewall change.

`thebeyond`'s existing `dmz`, `ba-tunnel`, `external` zones stay as they
are. The `network` zone's character changes (see above) — what was
"AP/switch lockdown" becomes "router-adjacent infrastructure", which
includes phantasma. Importantly, the office-side trusted zones (`management`,
`trusted`, `lab`) are **removed from `thebeyond`'s zone list** in Phase 3
when their gateways move — they become `BT8-gateway`'s problem. The
hostile zones (`untrusted`, `iot`, `game`, `adu`) stay on `thebeyond`
per the hostile-zone convergence decision; only their L2 fabric
passes through the BT8 mesh.

On `BT8-gateway` (OpenWrt fw4 zone semantics, named to mirror router6):

| fw4 zone     | networks bound        | input    | forward | masq | output |
|--------------|-----------------------|----------|---------|------|--------|
| `transit`    | `transit` interface   | REJECT   | REJECT  | no   | ACCEPT |
| `app`        | APP VLAN (50)         | REJECT   | REJECT  | no   | ACCEPT |
| `management` | INFRA VLAN (11)       | ACCEPT (services as needed) | REJECT | no | ACCEPT |
| `trusted`    | HOME VLAN (20)        | ACCEPT   | REJECT  | no   | ACCEPT |
| `lab`        | LAB VLAN (21)         | ACCEPT (services) | REJECT | no | ACCEPT |

`untrusted` (GUEST/IOT/GAME/ADU) is *not* a fw4 zone on BT8-gateway —
those VLANs are L2-only batman passthrough on this device. Their L3
firewall enforcement happens on `thebeyond` (the existing `untrusted`
zone in `router6`).

Forward rules between zones are configured per-pair in OpenWrt's
`firewall.@forwarding[…]` UCI, mirroring the router6 `accessTo` semantics:
- `trusted → app, management, lab, transit` (mirrors current
  trusted `accessTo` minus the hostile-zone family; trusted→untrusted/iot
  now traverse transit and are governed by `thebeyond`'s `transit →
  untrusted` / `transit → iot` policies). The `transit` forward here is
  the catch-all that lets HOME reach IoT/GUEST endpoints (and DMZ +
  internet) — fw4 trusts thebeyond's transit-zone forwardRules to do the
  source/destination filtering.
- `lab → management, lab, transit`.
- `app → transit` and selective forwards to `management` (mirrors what
  DMZ has on `thebeyond` today: ACME, Loki, Authelia OIDC).
- `management → management, trusted, app, transit` (mirrors current
  management `accessTo` minus the hostile-zone family; same caveat as
  `trusted` — any management→untrusted/iot access lands on `thebeyond`
  via transit).

## Phases

Each phase ends in a state where the network is functional. Plans that touch
the same files (Authelia, x5c, ipv6-gua-stable-ingress) should sequence around
this plan, not against it.

### Phase 0 — Bring `thebeyond` online; current BT8 stays as office gateway temporarily

**Goal:** `thebeyond` replaces the current BT8 as the primary internet
gateway. The current BT8 is reconfigured into a transitional role (still
gatewaying office-side VLANs) so the network keeps working while we iterate
on the long-term dual-gateway design with the second BT8.

**Why this shape:** we don't want to bring online the dual-gateway model and
the new physical gateway at the same time. Phase 0 isolates the
hardware-and-physical-topology change; Phase 2/3 isolates the
multi-gateway-firewall change.

**Why split into 0a / 0b:** the bundle is large (registry refactor +
batman-over-wire + bond0 removal + phantasma re-IP + first-ever boot of
thebeyond + BT8-bridge UCI flip). `deploy-rs magic_rollback` only covers
thebeyond's NixOS config — it does not roll back the registry refactor
(which propagates to every host's `mkExtraHosts` / `mkUnboundLocalData` /
egress rules), the physical hardware swap, or the BT8-bridge UCI. 0a
keeps everything that can be validated without touching production in
one no-deploy commit; 0b is the cutover proper.

#### Phase 0a — Validation in code (no deploy)

Steps:
1. **Incidental cleanup: drop the stale `MEDIA = {tag = 42;}` entry**
   from `switchVlans` in `lib/common/data/openwrt.nix`. There is no
   media VLAN; the `media` firewall zone exists only to gate what
   `wg-media` peers can reach, and the stale switch tag is misleading.
   Independent of the rest of Phase 0a, but lands in the same no-deploy
   commit.
2. **Pre-flight: pin the OpenWrt release for BT8.** BT8 hardware is
   already in production as the existing prod gateway and as 4 mesh APs
   (per resolved decision #2), so target support exists. The question is
   only which release to pin. Verify against the OpenWrt support matrix
   that `mediatek/filogic` (MT7988A) is current in the release the
   project is pinning via `openwrt-hashes.json` `defaultRelease`, and
   that no regressions land on the release for switch/wireless drivers.
   Run `nix run .#openwrt-build -- <bt8-mesh-device> --update-pins` to
   confirm hash availability. If support has regressed, defer to a
   stable release.
3. **Pre-flight: enable PD client on thebeyond's WAN.** The current
   `hosts/thebeyond/router.nix` WAN block is plain `type = "dhcp"` with
   no `ipv6PrefixDelegation` set, which means thebeyond would request
   no delegated prefix at all. Add the PD client (we expect `/64` per
   the [IPv6 baseline](#ipv6) — the request is for visibility and to
   stamp the delegated prefix on the WAN interface, not for
   subdivision):

   ```nix
   wan = {
     mac = "00:e0:67:1b:70:34";
     network = {
       type = "dhcp";
       zone = "external";
       nat.enable = true;
       defaultRoute = true;
       ipv6PrefixDelegation = {
         enable = true;
         prefixLength = 60;   # polite hint; ISP delegates /64 in practice
       };
     };
   };
   ```

   `WithoutRA = "solicit"` is already set in the router6 networking module,
   so the DHCPv6 client will send solicits even if the ISP's RA doesn't set
   the M flag.

4. **Drop `bond0` from `thebeyond`'s topology** in the source tree (no
   deploy yet — this lands as part of Phase 0a's no-deploy commit). The
   new hardware uses a single wired NIC as `bat0`'s hard interface
   (instead of `bond0` over `lan` + `opt1`). Update
   `hosts/thebeyond/router.nix`:
   - Remove the `lan` + `opt1` MAC entries' role as bond members.
   - Remove the `bond0` block entirely.
   - Make the chosen NIC (e.g., `lan`) the sole member of `bat0`.
   - **Move `mtu = 1536` from the (deleted) `bond0` block onto the chosen
     NIC's `network` block.** `bond0` carried the 25-byte batman headroom
     today; with bond0 gone, that MTU has to land on the wired hard
     interface directly or batman frames will fragment.
   - Simplify `mkVlanBridge` to drop the `bond0Vlans` attribute and the
     `v${name}.bond0` member — bridges become `bat0`-only.

   **Note:** since the wired link to `BT8-bridge` is now batman-encapsulated,
   nothing else can connect to that wire as a plain VLAN trunk. That's
   fine for this topology; flag it in operator handover.

   **Same first-deploy: registry refactor for the per-gateway split,
   plus phantasma's VLAN move.** Bundling both changes into the first
   deploy avoids re-IPing phantasma twice. Concretely:
   - **Registry refactor** in `lib/common/data/network.nix`:
     introduce the `gateways` table
     (`thebeyond.prefix4 = "10.91"`, `thebeyond.ulaGroup = 0`;
     `bt8gw.prefix4 = "10.97"`, `bt8gw.ulaGroup = 1`); add the
     `gateway` field to every existing zone; refactor `rawNetworks`
     enrichment and `mkHost` to derive `subnet4`/`subnet6`/`gateway4`/
     `gateway6`/host CIDRs from the per-zone `prefix4`/`prefix6` (plus
     the per-zone `prefixLength4`/`prefixLength6`, defaulting to 24 /
     64). Make `hostRangeCheck` prefix-length-aware. Add a pure-eval
     test under `tests/lib/` covering at least one prefix-length
     override against a synthetic fixture (transit isn't in the
     registry yet — Phase 1 adds it — but the helper logic is what
     the test exercises, and a synthetic `/30` zone is a perfectly
     fine fixture).
   - **DMZ stays at `10.97.100.0/24` for now** via an explicit
     `prefix4 = "10.97.100"` override on the `dmz` zone, so existing
     DMZ residents (`langport`, `trista`, `oracion`, `creil`, `zeiss`,
     `saint-arkh`) don't re-IP in Phase 0. The override is dropped
     at the end of Phase 5 once the APP-bound services have moved
     and only `langport` and `trista` remain on DMZ. IPv6 for DMZ
     is unaffected — VLAN 100 in thebeyond's group-0 slice produces
     `fdc6:55f2:0a5e:0064::/64`, same as today.
   - **Move phantasma from VLAN 11 (INFRA) to VLAN 10 (`network`)
     and re-number to host ID 10.** Since `network.gateway =
     "thebeyond"` and there is no `prefix4` override on `network`, the
     refactor places phantasma at `10.91.10.10` and
     `fdc6:55f2:0a5e:000a::a` directly — single re-IP at first deploy.
     Concretely:
     - In `lib/common/data/network.nix`, remove `phantasma = 2` from
       `management.hosts` and add `phantasma = 10` to `network.hosts`
       (alongside the permanent `bt8bridge = 4` entry per the
       [host-ID convention](#network-host-id-convention); BT8-gateway
       deliberately has no `network.hosts` entry).
     - In `hosts/thebeyond/microvm/guests/phantasma/microvm.nix`,
       rename the tap from `vm-11-phantasma` to `vm-10-phantasma`
       (`microvm.interfaces[].id`) and update the MAC from
       `5E:11:AD:01:00:02` to `5E:0A:AD:01:00:0A`. The second octet
       encodes the VLAN ID in hex (`0x0A` = 10) per existing
       convention; the last octet (`0A`) encodes the new host ID 10.
     - In `hosts/thebeyond/router.nix`, replace
       `systemd.network.networks."10-vm-infra"` with a `10-vm-network`
       rule that matches `vm-10-*` and bridges to `brMGMT`. Keep the
       `vm-11-*` → `brINFRA` rule for any future INFRA-resident
       microvms.
     - Add `udp dport 53` and `tcp dport 53` input rules to the
       `network` zone in `router6.zones` so phantasma can serve DNS
       on its new segment. (NTP is already permitted on `network`.)
     - Update phantasma's microvm config if it pins its own IP, to
       `10.91.10.10`. Otherwise the registry-derived helpers
       (`mkExtraHosts`, `mkUnboundLocalData`) regenerate automatically.

   Other thebeyond-owned zones (`network`, `ba-tunnel`, `external`,
   `media`) re-derive at the new `10.91` prefix. Of those, `network`
   has phantasma (just moved); the rest are wireguard- or WAN-bound
   and don't have registry hosts that change IP. BT8-gateway-owned
   zones stay at `10.97` (no IP change for any existing host).

   - **Reconcile stale `network.hosts` entries.** Today's registry
     carries five E8450 mesh-AP entries (`merkabah = 20`,
     `derfflinger = 21`, `pantagruel = 22`, `bobcat = 23`,
     `lusitania = 24`) and an `arseille = 12` entry. Per the
     [non-goals](#non-goals), four of five E8450s have already been
     physically pulled, and `arseille` is being deferred to a
     follow-up plan. As part of the registry refactor, drop the four
     pulled E8450 entries from `network.hosts` so post-refactor
     `mkExtraHosts` / `mkUnboundLocalData` don't keep emitting DNS
     and `/etc/hosts` records for hardware that no longer exists.
     Identify the four pulled units against current physical
     inventory; leave the surviving one in place for now (it can
     be renumbered or removed by whichever follow-up plan owns the
     final E8450 decommission). `arseille` likewise stays in the
     registry until its follow-up plan reclassifies or removes it.

   ULA addresses on BT8-gateway-owned zones do shift (e.g.,
   `:0014::<host>` → `:1014::<host>` for HOME) — automatic via the
   registry. Internal-only, no GUA, no inbound v6, so the operational
   impact is essentially zero.
5. **VM-level validation of the new topology before any hardware
   moves.** Add (or extend) a `tests/modules/router6-batman-wired-only.nix`
   NixOS test that mirrors the post-refactor `mkVlanBridge` shape on a
   stub network. Asserts:
   - bridges have only `bat0.<tag>` members (no `bond0Vlans`).
   - the wired NIC's network block carries `mtu = 1536`.
   - the registry-derived addresses for thebeyond's owned zones land
     under `10.91.x.x` and `fdc6:55f2:0a5e:000x::/64`.
   - phantasma's microvm tap matches `vm-10-*` and is bridged onto
     `brMGMT`.
   Also run the existing test suite (`./scripts/run-checks.sh`) and a
   pure-eval test for the per-prefix-length helpers. **0a does not
   merge until all checks pass.**
6. **Generic router6 listening-socket audit test.** No existing test
   runs `ss -tlnp`/`ulnp` to catch services accidentally bound
   wildcard (`0.0.0.0` / `[::]`). A wildcard-bound kresd/kea is
   still firewall-blocked, but defense-in-depth prefers explicit
   interface bind so a firewall mistake doesn't immediately mean
   exposure — and the assertions in step 7 don't cover this class
   of mistake.

   Add `tests/modules/router6-listening-sockets.nix` that boots a
   minimal router6 with the typical service set the module wires up
   (kresd as DNS resolver, plus whatever else the module enables by
   default — kea is enabled per-zone, so configure it on at least one
   zone) and asserts via `ss -tlnp` and `ss -ulnp` that no service
   binds to `0.0.0.0` or `[::]`. Each module-managed service should
   be bound to a specific internal interface, never wildcard.

   This is the smallest possible test (one VM, no attacker peer
   needed) and is generic to the module. If `router6` ever wires up
   a new service, this test forces the author to think about the
   bind interface upfront.

   Skip duplicating: TCP-stealth-on-closed-port (covered by
   `router6-firewall.nix` Test 3), ICMP echo dropped (Test 4), drop
   policy active (Test 1), inter-zone forward matrix (covered by
   `router6-firewall-zones.nix`), UDP-stealth empirical scan (the
   step 7 assertions catch the regression class structurally; the
   Phase 0b runbook's UDP scan covers the residual gap empirically —
   a third synthetic-network layer adds little), the external-zone
   accept set on thebeyond specifically (better caught by Phase 0b's
   empirical scan than by a VM test that re-imports thebeyond's full
   config with all its microvm/sops dependencies).

   Run `./scripts/run-checks.sh router6-listening-sockets` alongside
   the full suite.
7. **Eval-time security assertions in router6.** Cheaper and earlier
   than the VM tests — fire at flake evaluation, no build needed.
   Add three small universal assertions to `modules/router6/default.nix`'s
   existing `assertions` list. All three are scoped to the router6
   module itself (extractable; not project-specific). Trust-level
   taxonomies and project-specific zone-policy enforcement are
   deliberately *not* added here — those belong in a project-side
   layer (e.g., on top of `lib/common/data/network.nix`) if needed
   later. WG listen-port uniqueness is also deliberately omitted:
   the runtime service-start failure is loud enough that an
   eval-time assertion adds little.

   The three assertions:

   **(a) WAN zones accept wireguard only.** Derive `wanZones`
   (zones bound to interfaces with `nat.enable = true`, via the
   existing `natInterfaces` helper in `lib.nix:131`) and `wgPorts`
   (listen ports of configured wireguard interfaces,
   `cfg.topology.*.wireguard.port`). Assert every rule in each WAN
   zone's `inputRules` is "wireguard-shaped" — `verdict = "accept"`,
   `udp.dport` set, every port in `wgPorts`. Anything else (TCP
   accept, UDP on a non-WG port, missing verdict) fails evaluation
   with a message naming the zone, rule index, and the legitimate
   escape hatch (`extraInputRules`). ~30 lines. **This is the
   load-bearing one** — it catches the regression class the operator
   is most worried about.

   **(b) No DHCP server on a NAT (WAN) interface.** Direct
   counterpart to the existing dhcp6 assertion at `default.nix:770-779`,
   just keying off `dhcp.enable` on a NAT-flagged interface instead
   of `dhcp6.enable` on a DHCP-client interface. Catches "Kea
   accidentally enabled on WAN" — would advertise the router as a
   DHCP server to the ISP segment. ~5 lines, mirrors the existing
   pattern exactly. Cheap addition alongside (a).

   **(c) `icmpEcho = "disable"` on NAT zones.** A NAT-enabled zone
   with `icmpEcho = "enable"` means the router answers pings from
   the public internet — info leak plus a (small) amplification
   surface. ~5 lines, reuses the same `wanZones` derivation as (a).
   Cheap addition alongside (a).

   ~40 lines total in the existing assertion block; the patterns to
   mirror are already in `default.nix` lines 770 (per-interface
   condition) and 821 (per-zone iteration). Cover with pure-eval
   tests under `tests/lib/` — one positive and one negative case per
   assertion — constructed against minimal synthetic configs. No VM
   tests needed for the assertions themselves.

   Layered defense for the WAN attack surface:
   - **Assertions (this step)** — structural, eval-time. Cheapest
     possible signal. Catches the three classes of mistake above
     before any build.
   - **External scan runbook (Phase 0b step 12)** — empirical, real
     hardware. Catches CPE/ISP-side surprises and any runtime gap
     between what the assertion proved structurally and what the
     kernel actually drops.

   **0a does not merge until (5), (6), (7), and the existing suite
   all pass.**

After Phase 0a: source tree is in the post-refactor shape, validated
by tests, with no hardware change. Network is still on the existing
gateway, unchanged.

#### Phase 0b — Hardware cutover (single maintenance window)

Steps (continuing the numbering):

6. Stage `nixos-anywhere` from the Phase 0a build (bond0 removal,
   registry refactor, phantasma migration). Deploy `thebeyond` with
   **no other router config changes yet** — APP/transit are added in
   Phase 1, so the existing zones still gate everything on `thebeyond`.
7. Physically move `thebeyond` to the modem closet. Connect WAN to modem.
   `BT8-bridge` (the current production BT8 reconfigured in step 8)
   needs to end up alongside `thebeyond` in the modem closet so the
   inter-device wired link is short and the 802.11s "fat pipe" handles
   the long hop to the office; relocate it during this same maintenance
   window if it isn't already co-located. After relocation, verify mesh
   quality from BT8-bridge's new location (RSSI, batman throughput
   counters) before declaring the cutover successful — the mesh is the
   committed inter-gateway path post-Phase-3 (see
   [Risks: mesh fat pipe](#risks)).

   **Bootstrapping note.** `thebeyond`'s NIC is `bat0`'s hard interface
   from first boot, so the cable carries batman frames. The current
   production BT8 doesn't speak batman on its wired port yet, so the
   link is dead between step 7 and step 8. **During this gap the entire
   household loses internet egress and inter-VLAN routing**: NAT lives
   on `thebeyond`, and the office-side mesh has no path to it until the
   current BT8 is reconfigured into the wireless-bridge role. Same-VLAN,
   same-side traffic continues to work (the office mesh stays internally
   connected over `802.11s`), but everything else is offline. Execute
   steps 7 and 8 in close succession with the operator on-site at both
   devices, and schedule the cutover in a maintenance window
   (announce/expect ~10–30 min of internet downtime, +relocation time
   if the BT8 is moving rooms).
8. Reconfigure the current production BT8 (manually):
   - Remove its WAN interface (no longer the gateway).
   - Make it a "dumb AP" / wireless-bridge (effectively the
     [BT8-bridge config](#a-manual-setup-bt8-as-dumb-ap--wireless-bridge)).
   - Disable its firewall, NAT, DHCP server.
   - Keep its 802.11s mesh and AP radios so other office BT8s still
     associate.
   - Give it a single management IP on `network` VLAN.
9. Cutover: bring up `thebeyond`'s WAN; verify NAT, DHCP, DNS, internet
   reachability from each existing zone.
10. **Sanity-check IPv6 delegation size.** On `thebeyond`:

    ```sh
    networkctl status wan
    cat /var/lib/systemd/network/dhcp6-prefix-delegation/wan 2>/dev/null
    ```

    Expected: `/64`, matching the operator's prior measurement against
    the existing gateway. The ULA-only baseline is already what the rest
    of the plan assumes, so there is no decision to make at this step
    beyond documenting what was actually delegated. If the result is
    *unexpectedly larger* (`/60` or `/56`), file a follow-up to switch
    to the GUA-enabled posture in the
    [IPv6 — if the ISP ever enlarges the delegation](#ipv6--if-the-isp-ever-enlarges-the-delegation)
    section, but don't pivot Phase 1 work in flight.
11. The current production BT8 is now physically a dumb-AP-with-mesh.
    Going forward, we'll call this device **BT8-bridge**.
12. **External security scan against the live WAN edge.** Even with the
    Phase 0a tests green, the synthetic test network is not the real
    ISP edge — the CPE in front of the modem may bridge or NAT-traverse
    in unexpected ways, and the real WAN address is what matters. Run
    the [external scan runbook](#e-external-security-scan) from an
    off-network host (mobile hotspot or short-lived VPS) against
    `thebeyond`'s real WAN IPv4 (and IPv6 link address if the ISP
    delegated one in step 10). Expected result: TCP all-filtered, UDP
    no-port-closed signal anywhere, ICMP echo unanswered, only the
    three wireguard UDP ports reachable for an authenticated handshake.

    **Phase 0b is not declared done until this scan passes.** If the
    scan turns up an unexpected open port, the most likely culprits
    (in rough order of likelihood) are: ISP CPE forwarding traffic to
    a stale internal address, a service accidentally bound to
    `0.0.0.0` instead of an internal bridge, or an `external` zone
    input rule that wasn't pruned during the per-gateway-split
    refactor. Diagnose before relying on the system.

After Phase 0: single-gateway model on new hardware in the right physical
locations, registry refactored for the per-gateway split, phantasma on its
final IP (`10.91.10.10` / `fdc6:55f2:0a5e:000a::a`), IPv6 delegation size
known. DMZ residents still at `10.97.100.x` (override in place); they
renumber at the end of Phase 5.

### Phase 1 — Add APP and transit VLANs to the registry and `thebeyond`

**Goal:** plumbing for the new zones in place, no production traffic on them
yet. The registry refactor for per-gateway prefixes already landed in
Phase 0; this phase only adds the two new zones on top of it.

Steps:
1. Add `app`, `netmgmt`, and `transit` zones to `lib/common/data/network.nix`:
   - `app` — `vlanId = 50`, `gateway = "bt8gw"` (no host IPs assigned
     yet; populated as services migrate in Phase 5).
   - `netmgmt` — `vlanId = 12`, `gateway = "bt8gw"`, `hosts = {}`. No
     consumers in this plan; the zone exists as the BT8-gw-side
     architectural mirror of `network`/10 and gets populated by a
     follow-up plan when wired-to-BT8-gw network gear lands here.
   - `transit` — `vlanId = 99`, explicit `prefix4 = "10.255.255"`,
     `prefix6 = "${ulaPrefix}:ffff"`, `prefixLength4 = 30`, hosts =
     `{ thebeyond = 1; bt8gw = 2; }`.
2. Add corresponding `mkVlanBridge` entries in `hosts/thebeyond/router.nix`
   for both VLANs. APP is added as a member-only bridge with no IP on
   `thebeyond`; BT8-gateway becomes APP's gateway in Phase 2. Transit gets
   `10.255.255.1/30` and `fdc6:55f2:0a5e:ffff::1/64` on `thebeyond`'s side
   (point-to-point — registry now models it correctly).
3. Add `app` and `transit` zones to `router6.zones` per the
   [zone-wiring section](#zone-wiring) above. APP behaves like DMZ (no
   `accessTo`, restricted egress, selective forwards to management
   services); `transit` accepts ICMP + DNS + NTP on input (the DNS rules
   double as the kresd-on-transit binding signal — see the zone-wiring
   notes), with `accessTo = [ "external" "ba-tunnel" ]` and
   `forwardRules.dmz / iot / untrusted` covering the cross-gateway
   flows. The `network` zone's `accessTo` stays empty; cross-gateway DNS
   traffic terminates as input on `transit` and is served by kresd, not
   forwarded onto `network`.
4. Redeploy `thebeyond` (deploy-rs with magic rollback). The
   downstream OpenWRT homelab L2 switch (managed out-of-flake — see
   [Reference D](#d-reference-openwrt-homelab-l2-switch-out-of-flake))
   needs APP/transit VLANs trunked on its uplink to BT8-gateway and an
   address on `netmgmt`/12 once that VLAN is stood up; the operator
   updates its UCI directly. A follow-up plan will fold this switch
   into the flake.
After Phase 1: APP and transit zones exist on `thebeyond`; APP is
member-only, awaiting BT8-gateway in Phase 2. The transit zone listens
for DNS/NTP (kresd auto-binds via the `dnsInterfaces` derivation) and
forwards office-side traffic into DMZ + hostile zones per
`forwardRules`.

### Phase 2 — Manual proof: BT8-bridge and BT8-gateway

**Goal:** prove the dual-gateway routing/firewall model on a single VLAN
(start with APP) using BT8-gateway. No production cutover.

Steps:
1. Configure BT8-gateway by hand using the
   [BT8-gateway manual setup](#b-manual-setup-bt8-as-secondary-gateway). For
   this phase, only configure APP VLAN and transit VLAN — leave other VLANs
   for Phase 3.
2. **Introduce the `router6.routes` option** in `modules/router6/default.nix`
   and use it on `thebeyond` for the cross-gateway static routes.
   Translation to systemd-networkd is mechanical — group routes by
   `interface`, emit them under the corresponding network's
   `routes = [ { Route = { Destination = ...; Gateway = ...; Metric? = ...; }; } ]`
   list in `modules/router6/networking.nix`. Add a pure-Nix evaluation
   test (`tests/lib/router6-routes.nix`) asserting the generated config
   for a representative declaration.

   ```nix
   # modules/router6/default.nix — new top-level option
   router6.routes = mkOption {
     type = types.listOf (types.submodule {
       options = {
         destination = mkOption { type = types.str; };  # "10.97.0.0/16" or v6
         gateway     = mkOption { type = types.str; };  # "10.255.255.2" or v6
         interface   = mkOption { type = types.str; };  # "brTRANSIT"
         metric      = mkOption { type = types.nullOr types.int; default = null; };
       };
     });
     default = [];
     description = "Static routes added to systemd-networkd on the
       interface specified. Used for cross-gateway reachability where
       no protocol carries the route automatically.";
   };
   ```

   With the per-gateway split, the cross-gateway routes are a single
   entry per protocol — covers APP, INFRA, HOME, LAB, NETMGMT in one
   shot (hostile zones stay terminated on `thebeyond`, so they need no
   static routes):

   ```nix
   router6.routes = [
     { destination = "10.97.0.0/16";
       gateway = "10.255.255.2";
       interface = "brTRANSIT";
     }
     { destination = "fdc6:55f2:0a5e:1000::/52";
       gateway = "fdc6:55f2:0a5e:ffff::2";
       interface = "brTRANSIT";
     }
   ];
   ```

3. **Verify DMZ reachability via transit.** BT8-gateway's connected
   routes are the per-VLAN `/24`s for its own bridges (br-v11/12/20/
   21/50/99) — there is no `10.97.0.0/16` aggregate, so the default
   route via `10.255.255.1` already covers `10.97.100.x` (DMZ) without
   any extra static route. Confirm with `traceroute 10.97.100.41`
   from a BT8-gw-side host that the path is `host → BT8-gw →
   10.255.255.1 → thebeyond → langport`, and double-check with
   `ip route get 10.97.100.41` on BT8-gateway that the selected
   nexthop is `10.255.255.1` via `br-v99`. If the routing table
   somehow disagrees (unexpected aggregate from a DHCP option, manual
   misconfiguration, etc.), a more-specific `10.97.100.0/24 via
   10.255.255.1 dev br-v99` route forces the right nexthop — but it
   shouldn't be necessary.
4. On BT8-gateway, configure DHCP for APP VLAN (odhcpd). Connect a test
   device to APP VLAN (via the homelab L2 switch's access port or
   directly via wifi if a test SSID is bound to APP).
5. Verify:
   - **DMZ L2 passthrough is not subject to fw4.** OpenWrt's
     `br-netfilter` is sometimes enabled by default, which would push
     bridge-only traffic through the L3 firewall and drop DMZ frames
     transiting BT8-gateway. Confirm `sysctl net.bridge.bridge-nf-call-iptables`
     reports `0`, and run an `nft monitor trace` (or `tcpdump` on
     `br-v100`) while a DMZ-resident host pings across the mesh to make
     sure the bridge path is clean. If `br-netfilter` is on, either
     disable it or add explicit fw4 accept rules for the DMZ bridge.
   - Test device on APP receives DHCP from BT8-gateway.
   - Test device reaches internet (egress through `thebeyond`'s NAT).
   - Test device reaches `phantasma` indirectly via thebeyond's local
     resolver at `10.255.255.1`: the test device's resolver is
     BT8-gateway's dnsmasq, which forwards to `10.255.255.1`, which
     recurses via phantasma. Confirm `dig @10.97.50.1 example.com`
     returns from the test device, and `nft list ruleset | grep dport.*53`
     on `thebeyond` shows hits on the transit zone's DNS input rule.
     Also confirm `ss -tlnp 'sport = :53'` on `thebeyond` lists kresd
     bound to `10.255.255.1:53` (auto-bound via `dnsInterfaces` from
     the transit zone's input rules).
   - Test device → DMZ host (e.g., `langport`): traffic must flow
     APP-host → BT8-gateway → transit → `thebeyond` → DMZ. Confirm via
     `traceroute` and `tcpdump` on the transit VLAN. BT8-gateway has
     no `10.97.0.0/16` aggregate (only per-VLAN `/24`s), so the
     default route via `10.255.255.1` reaches DMZ without any
     special handling — step 3 verifies this.
6. Document any UCI snippets or kernel-tuning that turned out to be needed
   in the [Phase 4 implementation notes](#phase-4--codify-bt8-gateway-and-bt8-bridge-in-image-builder).

After Phase 2: we know the model works for one VLAN. Manual config exists on
BT8-gateway but is not yet image-built.

### Phase 3 — Production cutover of office-side VLAN gateways

**Goal:** move the trusted office-side VLAN gateways (INFRA/11,
HOME/20, LAB/21) from `thebeyond` to BT8-gateway. APP/50 is already
gatewayed by BT8-gateway from Phase 2 onward (`thebeyond` only ever
had a member-only APP bridge for `bat0.50` termination, no L3) so
it doesn't cut over — it just stays in its no-op-by-design shape on
`thebeyond`. Hostile zones (GUEST/30, ADU/31, IOT/40, GAME/41) stay
terminated on `thebeyond` per the hostile-zone convergence decision
and don't cut over either. The per-gateway IP-space split makes the cutover simpler than
it would otherwise be: BT8-gateway holds `10.97.x.1` natively from
the moment it comes up — no `.2` transition address, no two-step
DHCP migration. Each migrated VLAN sees a single cutover event (a
sub-second ARP flip + gratuitous ARP).

Steps:
1. Physically install BT8-gateway in its production location in the
   office.
2. On BT8-gateway (manually, building on Phase 2 config), add the
   remaining BT8-gateway-terminated VLANs: INFRA (11), HOME (20),
   LAB (21). For each: bridge, fw4 zone binding, odhcpd config — all
   in place, but **leave the bridge without an IP and odhcpd disabled
   for now**. BT8-gateway is fully provisioned but inert on these
   VLANs; thebeyond still holds `.1` and Kea still serves leases.

   GUEST (30), ADU (31), IOT (40), GAME (41) are *not* migrating —
   they stay terminated on thebeyond per the hostile-zone convergence
   decision. On BT8-gateway, those bridges already exist as L2-only
   passthrough from Phase 2 (`proto 'none'`). No cutover work needed
   for them in this phase.

3. **Per-VLAN cutover** (can be all-at-once or one-VLAN-at-a-time;
   each VLAN's cutover is independent). The full sequence is a single
   scripted SSH transaction so the no-`.1` window is sub-second:

   ```sh
   # Run from operator workstation; substitute <vlan>, <iface> per VLAN.
   ssh root@thebeyond    "systemctl stop kea-dhcp4-server@<vlan>" && \
   ssh root@thebeyond    "ip addr del 10.97.<vlan>.1/24 dev brV<vlan>" && \
   ssh root@thebeyond    "ip -6 addr del fdc6:55f2:0a5e:1<vlanHex>::1/64 dev brV<vlan>" && \
   ssh root@bt8-gateway  "ip addr add 10.97.<vlan>.1/24 dev br-v<vlan>" && \
   ssh root@bt8-gateway  "ip -6 addr add fdc6:55f2:0a5e:1<vlanHex>::1/64 dev br-v<vlan>" && \
   ssh root@bt8-gateway  "/etc/init.d/odhcpd start <vlan>" && \
   ssh root@bt8-gateway  "arping -c 3 -A -I br-v<vlan> 10.97.<vlan>.1"
   ```

   The actual Kea unit name (`kea-dhcp4-server@<vlan>`) and any
   IPv6/RA-server stop commands depend on how thebeyond's services are
   structured; substitute as needed. `arping -A` (gratuitous ARP,
   sender = target) is the standard way to announce an IP→MAC change
   on a shared L2.

   Existing client leases continue to point at `.1`; they keep
   working because `.1` is now BT8-gateway. Brief ARP-cache flap on
   clients (a few hundred ms typically), then convergence.

4. Apply on `thebeyond`:
   - Remove the IPv4 + IPv6 gateway addresses from the bridges for
     migrated VLANs. Keep the bridges themselves (they exist purely
     as the `bat0.<tag>` termination on `thebeyond`'s side of the
     batman fabric — without them, frames for those VLANs have
     nowhere to land on `thebeyond`). Just drop the `addresses`
     and `dhcp.enable` from the bridge's network block.
   - The cross-gateway static routes (`10.97.0.0/16 via 10.255.255.2`
     and `fdc6:55f2:0a5e:1000::/52 via fdc6:55f2:0a5e:ffff::2`) already
     landed in Phase 2 via `router6.routes`. No change needed in this
     phase — confirm they're still present after the deploy.
   - Remove the migrated *trusted* zones (`management`, `trusted`,
     `lab`) from `router6.zones`. Their bridges have no further role
     on `thebeyond` — frames for those VLANs are L3-terminated on
     BT8-gateway, and `thebeyond` doesn't need to host the bat0.<tag>
     termination for VLANs that no thebeyond-resident host consumes.
     Drop the zone definitions and the corresponding `mkVlanBridge`
     entries together.
   - **Keep `app` in `router6.zones` as a no-op-by-design zone.**
     Even though APP's L3 gateway lives on BT8-gateway, `thebeyond`
     still needs the `brVAPP` bridge for `bat0.50` termination on
     its side of the batman fabric (mirror of how GUEST/ADU/IOT/GAME
     exist as L2-only passthrough on *BT8-gateway* per the
     hostile-zone convergence decision). The bridge stays
     member-only with no IP, no DHCP, no `inputRules`, and no
     `forwardRules`; the zone exists purely so the topology system
     has a home to bind the bridge to. If a thebeyond-resident
     service ever needs to reach APP directly, that motion lives
     in a follow-up plan, not here.
   - Keep everything else — `network`, `dmz`, `transit`, `external`,
     `ba-tunnel`, `media`, and the *entire* `untrusted` family
     (`untrusted`, `iot`, `game`, `adu`) which now stays on
     `thebeyond` per the hostile-zone convergence decision.
   - Remove DHCP definitions for migrated VLANs from Kea.
   - Update IPv6: stop running DHCPv6-PD server on the migrated VLANs.
5. Verify: every existing host reaches its expected peers (DMZ ↔ APP ↔
   GUEST ↔ INFRA paths through the right gateway); operator workstation
   can SSH to `thebeyond`, `BT8-bridge`, and `BT8-gateway`.
6. **Re-run the [external scan runbook](#e-external-security-scan).**
   Phase 3 is the largest single change to `thebeyond`'s zone topology
   in this plan (trusted zones removed, transit zone now active). Re-
   scan to confirm the WAN surface is unchanged. Pay particular
   attention to step 5 (internal listening-socket spot-check) and
   step 6 (rendered ruleset review) — the rule re-derivation is what
   most plausibly leaks something inadvertently, and those steps are
   the ones that catch it.

After Phase 3: dual-gateway model is production. Manual UCI on
`BT8-gateway` and `BT8-bridge`. DMZ residents still at `10.97.100.x`
pending Phase 5 renumber.

### Phase 4 — Codify BT8-gateway and BT8-bridge in Image Builder

**Goal:** replace manual UCI with declarative device profiles in
`hosts/openwrt/`.

Steps:
1. Extend `lib/common/data/openwrt.nix`:
   - Add BT8 target/subtarget (verified during Phase 0 pre-flight; pin
     the Image Builder hash via `nix run .#openwrt-build -- --update-pins`).
   - Audit the existing `meshVlans` table — with `batman-adv` carrying VLANs
     through the mesh, every VLAN trunked over the wired link is also a
     mesh VLAN. The current short list (MGMT, HOME) is no longer accurate.
2. Define two new `type` values for OpenWrt device declarations:
   - `wirelessBridge` — flat L2 bridge across wired uplink + batman-adv
     mesh. Inputs: trunk VLANs, mesh ID, mesh PSK ref, mesh radio binding.
     Outputs: a working dumb-AP-with-mesh UCI tree.
   - `gateway` — secondary gateway with per-VLAN bridges, fw4 zone
     bindings, odhcpd, batman-adv mesh participation, optional client AP
     SSIDs. Consumes a structured zone description from `network.nix`.
3. Extend the existing `meshAP` type to accept BT8 hardware (target +
   packages list) so the rest of the BT8 mesh fleet can be image-built
   alongside the gateway and bridge.
4. Generate fw4 UCI from a structured zone description in Nix. Reuse the
   zone names from `network.nix`; the Image Builder turns them into UCI
   `firewall.zone[...]` and `firewall.forwarding[...]` entries.
5. Generate odhcpd UCI per VLAN from registry data (subnet, gateway, DNS).
6. Add tests under `tests/openwrt/` — pure-Nix evaluation tests asserting
   the UCI output for representative configurations matches expected
   snapshots.
7. Cutover the manually-configured BT8-bridge and BT8-gateway to
   image-builder-generated images one device at a time. Build the image,
   stage it via `nix run .#openwrt-build`, then `openwrt-deploy` with the
   manual UCI captured as a backup so we can fall back to a
   sysupgrade-restore if the image-built device misbehaves. Mgmt-plane
   posture stays as it is today (SSH from `network`); locking it down is
   deferred to Phase 4.5 so the cutover doesn't risk locking us out of an
   image-built device with no manual UCI fallback.

After Phase 4: `BT8-gateway` and `BT8-bridge` are managed declaratively, in
band with the rest of the OpenWrt fleet. Mgmt-plane posture is unchanged
from Phase 3 (handled separately in Phase 4.5).

### Phase 4.5 — Lock down BT8-gateway/BT8-bridge management plane

**Goal:** restrict SSH (and LuCI if present) on `BT8-gateway` and
`BT8-bridge` to a designated set of management hosts, mirroring the
L3-switch-mgmt-interface posture.

**Why a separate phase from Phase 4:** an image-built device with an SSH
allowlist that doesn't actually contain a working management host is a
hard lockout — recovery means serial console or factory reset. Splitting
this off lets us cut over to image-built profiles first (Phase 4),
confirm SSH from the designated management hosts works on the existing
posture, *then* tighten in this phase as a small, focused diff.

Steps:
1. Decide the management-host allowlist. At minimum: the operator's
   workstation source IPs on `network` and `management`, plus the future
   pusher host once its zone placement lands. Document the allowlist in
   the OpenWrt zone description so it's reviewable in code.
2. Add an `inputRules` (or fw4 equivalent) restriction to the BT8 zone
   description: drop SSH (port 22) and LuCI (80/443 if enabled) from
   sources outside the allowlist.
3. Build a new image with the lockdown applied. Before deploying, dry-run
   the rule by adding the same restriction via runtime UCI on
   `BT8-gateway` (`fw4 reload`), confirm the operator can still SSH in,
   then revert the runtime change. This catches an empty-allowlist
   misconfiguration without needing a factory reset.
4. Deploy the image-built lockdown to `BT8-gateway` first (it's the
   higher-touch device), verify, then deploy to `BT8-bridge`.
5. Capture the pre-lockdown UCI as the rollback artifact so a single
   `sysupgrade -r <backup>` recovers the looser posture if the lockdown
   misbehaves.

After Phase 4.5: mgmt-plane access on both BT8s is restricted to an
explicit allowlist, declared in code, applied consistently across every
image rebuild.

### Phase 5 — Move services into APP

**Goal:** populate the APP zone with services that fit there.

Move candidates (subject to Authelia migration sequencing):
- `oracion` (Jellyfin) — already DMZ-flagged, but only consumed internally
  via wg-media. Could move to APP.
- `creil` (Forgejo internal) — same logic.
- `zeiss` (Attic) — `saint-arkh` pushes to it, `thebeyond` package mirror
  pulls from it. No internet egress needed; APP fits.
- `saint-arkh` (CI runners) — internal CI coordinator; the actual job
  containers stay in DMZ. APP candidate.

**Stays in DMZ:**
- `langport` (reverse proxy, internet-exposed via 80/443).
- `trista` (SSH bastion, internet-exposed via wg-ba).

Each move includes:
1. Re-IP the host into APP (`10.97.50.x`), update the registry.
2. Update DNS (`mkUnboundLocalData` consumers regenerate automatically).
3. **Apply the DMZ host-hardening profile** to the moved host:
   - Host-level input firewall (per the existing per-host `networking.firewall`
     pattern used on DMZ hosts).
   - Host-level egress filter via `pkgs.mmell.lib.nftables.mkEgressFilter`,
     with rule strings produced by `pkgs.mmell.lib.data.network.mkEgressRules`
     (same as today's vDMZ hosts).
4. **Re-derive cross-gateway forward rules.** Any rule that previously
   targeted the host on DMZ via `thebeyond`'s zone semantics now needs an
   equivalent on `BT8-gateway`. For inbound traffic that originates from a
   `thebeyond`-side zone (wg-media, wg-vpn, wg-ba, etc.), the path is
   `<src-zone-on-thebeyond> → transit → BT8-gateway → app → <host>`, so
   `BT8-gateway`'s `app` zone needs a `transit → app` forward rule
   source-restricted to the relevant peer subnet and dest-restricted to
   the host + ports. **Required for oracion**: when oracion moves to APP,
   add a `transit → app` rule on `BT8-gateway` sourced from
   `10.100.20.0/24` (wg-media) to `oracion` on the Jellyfin/Navidrome/
   Retrom ports — without it, every wg-media client silently breaks the
   moment oracion is re-IPed. Other moves (creil, zeiss, saint-arkh) are
   internally-consumed and don't trip this; check the host's existing
   inbound DMZ forward rules and translate any wg-* sources the same way.
5. Retest connectivity (in-zone, cross-zone-via-BT8-gateway, internet,
   and any wg-* paths affected by step 4).

After all candidate moves complete, only `langport` and `trista`
remain on DMZ. Drop the Phase-0 `prefix4 = "10.97.100"` override on
the `dmz` zone in `lib/common/data/network.nix`; the registry now
derives `10.91.100.0/24` from `dmz.gateway = "thebeyond"` (ULA stays
`fdc6:55f2:0a5e:0064::<host>`, unchanged from Phase 0). Re-IP
`langport` and `trista` to `10.91.100.41` and `10.91.100.51` using
the same dual-stack window pattern as the per-host moves above (host
briefly holds both addresses so in-flight connections survive, then
drop the old address). Update `thebeyond`'s `dmz` bridge to
`10.91.100.1/24`. Cloudflare DNS for `langport`'s WAN side is
unaffected; check `basel`'s step-ca issuance templates and re-issue
any cert whose SANs pinned `10.97.100.<id>`.

After Phase 5: APP zone populated; DMZ holds only `langport` and
`trista` at their final `10.91.100.x` addresses. The registry has no
special cases left for the address-space split.

## Manual setup procedures

These are the runbooks for Phase 0–3 (before Image Builder support exists).
Once Phase 4 ships, they become reference material rather than
operator instructions.

**Mesh PSK handling.** The `<MESH_PSK>` placeholder in both runbooks is the
same shared key used by the existing BT8 mesh fleet. During the manual
phases it is pasted in by hand from the operator's secret store (1Password
or equivalent). At Phase 4, the key flows through the
`openwrt-generalized-secrets` pipeline (sops-encrypted, decrypted at image
build / deploy time) so no plaintext lands in the repo or the Nix store.

### A. Manual setup: BT8 as "dumb AP" / wireless bridge (BT8-bridge)

**Role:** flat L2 fan-out across two `batman-adv` hard interfaces — the
wired link to `thebeyond` and `mesh0` (802.11s). Both legs are batman
hardifs on the same `bat0`, so VLAN-tagged frames traverse the mesh
natively without needing per-VLAN bridges on this device. Has a
single management IP on `bat0.10` for SSH/sysupgrade. No DHCP,
firewall, or routing.

**Assumptions:** stock OpenWrt 24.10+ flashed (BT8 hardware support
verified in Phase 0 pre-flight). Console access via the device's default
192.168.1.1 LAN port for initial setup. Only the management VLAN
(`10`) needs a sub-interface on this device; every other VLAN flows
through batman as opaque tagged frames.

#### 1. Initial setup

```sh
ssh root@192.168.1.1     # default after first-boot password set via web UI

opkg update
opkg install \
    luci \
    kmod-batman-adv batctl-default \
    luci-proto-batman-adv \
    iproute2-tc                       # only if you'll do queueing later
```

#### 2. Disable services that conflict with the dumb-AP role

```sh
/etc/init.d/firewall stop && /etc/init.d/firewall disable
/etc/init.d/dnsmasq stop && /etc/init.d/dnsmasq disable
/etc/init.d/odhcpd stop && /etc/init.d/odhcpd disable
```

#### 3. 802.11s mesh radio

Edit `/etc/config/wireless`. Pick the 5GHz radio (typically `radio1`) for
the mesh — leave the 2.4GHz radio (`radio0`) and 6GHz radio (`radio2`, if
present) for client APs that other plans might add later. `mesh_fwding 0`
hands forwarding to `batman-adv`, which is exactly what we want.

```uci
config wifi-iface 'mesh0'
    option device 'radio1'
    option network 'mesh'
    option mode 'mesh'
    option mesh_id 'home-mesh'
    option mesh_fwding '0'
    option encryption 'sae'
    option key '<MESH_PSK>'           # shared with all other BT8s
```

```uci
# Mesh interface itself has no L3 — batman-adv consumes it.
config interface 'mesh'
    option proto 'batadv_hardif'
    option master 'bat0'
    option mtu '1536'                 # batman-adv overhead headroom
```

#### 4. `batman-adv` virtual device with two hardifs

`/etc/config/network` — define `bat0`, attach the wired uplink as a
second batman hard interface alongside `mesh0`, and add the single
management sub-interface:

```uci
config interface 'bat0'
    option proto 'batadv'
    option routing_algo 'BATMAN_V'
    option gw_mode 'off'

# Wired uplink to thebeyond — second batman hardif (mesh0 is the first,
# defined in the wireless block above). Verify the actual port name with
# `ip link`; other lanN ports are unused on BT8-bridge.
config interface 'wired'
    option proto 'batadv_hardif'
    option master 'bat0'
    option mtu '1536'                 # batman-adv overhead headroom
    option ifname 'lan1'

# Management sub-interface on the shared batman fabric. This is the
# *only* VLAN sub-interface BT8-bridge needs — all other VLANs flow
# through bat0 as opaque tagged frames between the two hardifs.
config device
    option name 'bat0.10'
    option type '8021q'
    option ifname 'bat0'
    option vid '10'
```

The wired link from `thebeyond` to `lan1` is batman-encapsulated, not a
plain 802.1Q trunk — `thebeyond`'s side puts batman frames on the wire
(see [Mesh L2 layer](#mesh-l2-layer-batman-adv-over-80211s-and-over-wire-to-thebeyond)).
Anything plugged into BT8-bridge's wired uplink that doesn't speak
batman will not interoperate.

#### 5. Management IP on `bat0.10`

```uci
config interface 'mgmt'
    option device 'bat0.10'
    option proto 'static'
    option ipaddr '10.91.10.4'            # bt8bridge per registry (network.hosts.bt8bridge)
    option netmask '255.255.255.0'
    option gateway '10.91.10.1'           # thebeyond
    list dns '10.91.10.10'                # phantasma (now on network)
```

No other VLAN bridges or sub-interfaces are needed on BT8-bridge.
GUEST/IOT/HOME/etc. frames cross batman from `mesh0` to `lan1` (and
vice versa) without ever landing in the OpenWrt L3 stack.

#### 6. Verify

```sh
# batman-adv visibility — both mesh0 and lan1 should show as hardifs
batctl if                            # mesh0 + lan1 both listed
batctl n                             # neighbours: BT8-gateway via mesh0, thebeyond via lan1
batctl o                             # originator table covering the whole fabric

# bat0 carries the only VLAN sub-interface (bat0.10) for management
ip -d link show dev bat0
ip -d link show dev bat0.10

# VLAN traffic actually crossing — tcpdump on the bat0 master device
# shows tagged frames for every carried VLAN, since they're traversing
# batman without local termination
tcpdump -i bat0 -nne -c 10           # mixed VLAN tags expected post-Phase-1

# From thebeyond, confirm the wired hardif neighbour appears
ssh root@thebeyond 'batctl n'        # should list BT8-bridge over the wired hardif
```

Connect a test laptop to BT8-gateway's office-side wired/wireless ports
(not BT8-bridge — BT8-bridge has no client-facing access, just the two
batman hardifs) and confirm it receives DHCP from `BT8-gateway`
(post-Phase 2) or `thebeyond` (Phase 0).

#### 7. Lock down

```sh
/etc/init.d/firewall status        # inactive
/etc/init.d/dnsmasq status         # inactive
/etc/init.d/odhcpd status          # inactive
ip -4 addr show                    # only bat0.10 has an IP
ip -6 addr show                    # only bat0.10 has a non-link-local addr
```

### B. Manual setup: BT8 as secondary gateway (BT8-gateway)

**Role:** secondary gateway for the office-side VLANs. Runs DHCP, routes
between owned zones locally, forwards everything else (default route + DMZ
+ `network`) via transit VLAN to `thebeyond`. Also runs as a mesh node
(participates in `batman-adv` over `802.11s`) so the office mesh has a
wireless leg, and broadcasts client-facing AP SSIDs bound to the right
VLANs.

**Assumptions:** OpenWrt 24.10+ flashed; mesh ID and PSK already
established by `BT8-bridge`; transit VLAN tag (99) trunked end-to-end.

The hardware-side configuration (mesh radio, `batman-adv`, per-VLAN
bridges) follows the same shape as the bridge runbook. The differences
are: per-VLAN bridges get IPs (gateway role); odhcpd is enabled per VLAN;
fw4 zones enforce policy; client AP SSIDs get bound per-VLAN.

#### 1. Initial setup

```sh
ssh root@192.168.1.1

opkg update
opkg install \
    luci luci-app-firewall \
    kmod-batman-adv batctl-default luci-proto-batman-adv \
    odhcpd \
    luci-app-mesh
```

Wipe the default `lan` interface from `/etc/config/network` so we can
rebuild cleanly.

#### 2. 802.11s mesh + `batman-adv` (mirrors BT8-bridge)

```uci
# /etc/config/wireless
config wifi-iface 'mesh0'
    option device 'radio1'
    option network 'mesh'
    option mode 'mesh'
    option mesh_id 'home-mesh'
    option mesh_fwding '0'
    option encryption 'sae'
    option key '<MESH_PSK>'           # same value as BT8-bridge
```

```uci
# /etc/config/network
config interface 'mesh'
    option proto 'batadv_hardif'
    option master 'bat0'
    option mtu '1536'

config interface 'bat0'
    option proto 'batadv'
    option routing_algo 'BATMAN_V'
    option gw_mode 'off'

# Per-VLAN sub-interfaces of bat0 (one per carried VLAN).
# Required for both L3-terminating VLANs (11, 12, 20, 21, 50, 99) AND
# L2-only passthrough VLANs (10, 30, 31, 40, 41, 100) — without
# bat0.<tag>, frames for those VLANs have nowhere to land on this device.
# VLAN 10 (network) is passthrough so office-side dumb APs reach
# thebeyond via batman; BT8-gateway holds no L3 on it (Option 2).
config device
    option name 'bat0.50'
    option type '8021q'
    option ifname 'bat0'
    option vid '50'
# ... repeat for 10, 11, 12, 20, 21, 30, 31, 40, 41, 99, 100 ...
```

#### 3. Wired ports + per-VLAN bridges

```uci
# lan1, lan2, lan3 act as VLAN-tagged trunk ports for the homelab L2
# switch / direct clients. Tag the appropriate VLANs per port (varies
# per deployment).
config device
    option name 'lan1.50'
    option type '8021q'
    option ifname 'lan1'
    option vid '50'
# ... per port × per VLAN as needed ...

# Per-VLAN bridges: wired-side + bat0.<tag>.
config device
    option name 'br-v50'
    option type 'bridge'
    list ports 'bat0.50'
    list ports 'lan1.50'              # plus other lanN.50 if trunked

config interface 'app'
    option device 'br-v50'
    option proto 'static'
    option ipaddr '10.97.50.1'
    option netmask '255.255.255.0'
    # ULA-only baseline (see "IPv6" section): no `ip6assign` since there
    # is no GUA prefix to subdivide. ULA addresses on this bridge are
    # configured separately via `ip6addr` on a `static6` interface
    # (see below) or via the registry-derived odhcpd config; do NOT
    # add `option ip6assign '64'` here.
    list ip6addr 'fdc6:55f2:0a5e:1032::1/64'   # APP ULA gateway

# netmgmt — for wired-to-BT8-gw network gear. Locked down separately
# from management/11 so VM hosts and network gear don't share a plane.
# Concrete consumer in this plan: the existing OpenWRT-configured
# homelab L2 switch (managed out-of-flake) needs an address on this
# VLAN. Bringing that switch into the flake is a non-goal here — the
# operator updates its UCI directly once netmgmt is available.
config device
    option name 'br-v12'
    option type 'bridge'
    list ports 'bat0.12'
    list ports 'lan1.12'              # homelab L2 switch trunk port

config interface 'netmgmt'
    option device 'br-v12'
    option proto 'static'
    option ipaddr '10.97.12.1'
    option netmask '255.255.255.0'
    list ip6addr 'fdc6:55f2:0a5e:100c::1/64'   # netmgmt ULA gateway

# ... repeat for INFRA/management (11), HOME/trusted (20), LAB (21)
# — these are BT8-gateway-terminated. GUEST/30, ADU/31, IOT/40,
# GAME/41 are L2-only passthrough on this device (see below).
```

Transit VLAN (`/30` point-to-point with `thebeyond`):

```uci
config device
    option name 'br-v99'
    option type 'bridge'
    list ports 'bat0.99'              # transit reaches thebeyond via mesh→bridge
    list ports 'lan1.99'              # only if a wired path is available

config interface 'transit'
    option device 'br-v99'
    option proto 'static'
    option ipaddr '10.255.255.2'
    option netmask '255.255.255.252'  # /30
    option gateway '10.255.255.1'      # thebeyond — default route
    list dns '10.255.255.1'            # thebeyond's local resolver
                                       # (forwards to phantasma)

# IPv6 transit interface — ULA-only baseline. Static address; no
# DHCPv6-PD client (thebeyond is not running a PD server on transit
# under the ULA-only baseline — see "IPv6" section). Restore the
# `proto 'dhcpv6'` form only if/when the ISP enlarges the delegation
# and the GUA-enabled posture is adopted.
config interface 'transit6'
    option device 'br-v99'
    option proto 'static'
    list ip6addr 'fdc6:55f2:0a5e:ffff::2/64'
    option ip6gw 'fdc6:55f2:0a5e:ffff::1'
```

L2-only passthrough bridges — DMZ (100), GUEST/UNTRUSTED (30), ADU (31),
IOT (40), GAME (41). All are gatewayed by `thebeyond`; BT8-gateway is
just a fan-out point. Each bridge exists so SSIDs can bind to `network
'<name>'` and so `bat0.<tag>` has somewhere to land, but no IP is
configured on this device:

```uci
config device
    option name 'br-v100'              # DMZ: passthrough only
    option type 'bridge'
    list ports 'bat0.100'
    list ports 'lan1.100'
config interface 'v100'
    option device 'br-v100'
    option proto 'none'

config device
    option name 'br-v30'               # GUEST/UNTRUSTED: passthrough
    option type 'bridge'
    list ports 'bat0.30'
config interface 'guest'
    option device 'br-v30'
    option proto 'none'

config device
    option name 'br-v31'               # ADU: passthrough
    option type 'bridge'
    list ports 'bat0.31'
config interface 'adu'
    option device 'br-v31'
    option proto 'none'

config device
    option name 'br-v40'               # IOT: passthrough
    option type 'bridge'
    list ports 'bat0.40'
config interface 'iot'
    option device 'br-v40'
    option proto 'none'

config device
    option name 'br-v41'               # GAME: passthrough
    option type 'bridge'
    list ports 'bat0.41'
config interface 'game'
    option device 'br-v41'
    option proto 'none'
```

`network` (10) is L2-only passthrough on this device. Future managed
switches and additional BT8 mesh APs need VLAN 10 trunked to them,
so the bridge exists; BT8-gateway itself holds *no* L3 address on it
(hermetic east/west isolation — admin reachability and DNS go via
transit instead, configured in section 7 below).

```uci
config device
    option name 'br-v10'                 # network: L2 passthrough only
    option type 'bridge'
    list ports 'bat0.10'
    list ports 'lan1.10'
config interface 'v10'
    option device 'br-v10'
    option proto 'none'
```

#### 3a. Client AP SSIDs (per-VLAN, optional in early phases)

If the BT8-gateway is also broadcasting client SSIDs (it should — we want
the mesh to do double duty as the office wifi for clients on HOME, GUEST,
IOT, GAME, etc.), bind each SSID to the matching network. `batman-adv`
over `802.11s` ensures frames carry the right VLAN tag across the mesh.

The SSID-to-network binding works identically for L3-terminated VLANs
(home → trusted on this device) and for L2-only passthrough VLANs
(guest/iot/game → bridges with `proto 'none'`); in the latter case
client traffic flows straight through to `thebeyond` over batman.

```uci
config wifi-iface 'home_5g'
    option device 'radio1'             # same radio as mesh, or radio2 (6GHz)
    option network 'home'              # corresponds to br-v20 (L3 here)
    option mode 'ap'
    option encryption 'sae-mixed'
    option ssid '<home-ssid>'
    option key '<home-key>'

config wifi-iface 'guest_5g'
    option device 'radio1'
    option network 'guest'             # br-v30 (L2-only — L3 on thebeyond)
    option mode 'ap'
    option encryption 'sae-mixed'
    option ssid '<guest-ssid>'
    option key '<guest-key>'

# ... iot, game similar — bound to br-v40, br-v41 networks (also L2-only) ...
```

#### 4. Configure DHCP / RA per VLAN

Edit `/etc/config/dhcp`:

```uci
config dnsmasq
    option domainneeded '1'
    option boguspriv '1'
    option localise_queries '1'
    option rebind_protection '1'
    option local '/internal/'
    option domain 'internal'
    option authoritative '1'
    list server '10.255.255.1'       # thebeyond's local resolver
                                      # (forwards to phantasma — no
                                      # transit→network forward needed)

config dhcp 'app'
    option interface 'app'
    option start '100'
    option limit '100'
    option leasetime '12h'
    option dhcpv4 'server'
    option dhcpv6 'server'
    option ra 'server'
    list ra_flags 'managed-config' 'other-config'

# Repeat per VLAN — but only for BT8-gateway-terminated VLANs
# (trusted/20, lab/21, app/50). DHCP/RA for the L2-passthrough VLANs
# (network/10, guest/30, adu/31, iot/40, game/41, dmz/100) runs on
# thebeyond's Kea, not here.
# For management/INFRA and netmgmt, keep DHCP disabled — both planes
# use static IPs (registry-derived) so addresses are stable.
```

Static reservations matching the registry should be added per VLAN. The
exact UCI is straightforward but tedious; in Phase 4 the Image Builder
generates this from `lib/common/data/network.nix`.

#### 5. Configure firewall zones

Edit `/etc/config/firewall`. Define one zone per network role; bind the VLAN
interfaces to their zones; add forwarding pairs.

```uci
config defaults
    option syn_flood '1'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'

config zone 'transit'
    option name 'transit'
    list network 'transit' 'transit6'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option masq '0'                  # NO NAT here; thebeyond does NAT

config zone 'app'
    option name 'app'
    list network 'app'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'

config zone 'trusted'
    option name 'trusted'
    list network 'home'              # HOME VLAN
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'REJECT'

config zone 'netmgmt'
    option name 'netmgmt'
    list network 'netmgmt'           # br-v12: homelab L2 switch + future net gear
    option input 'REJECT'             # locked-down infra plane —
    option output 'ACCEPT'             # admin SSH gated by explicit rule below
    option forward 'REJECT'

# ... mgmt (binds br-v11), lab (binds br-v21) ...
# No fw4 zone for `network`/10 — VLAN 10 is L2-only passthrough on this
# device, no L3 interface to bind. Same for guest/iot/game/adu/dmz —
# their fw enforcement runs on thebeyond's router6 zones.

# Forwarding pairs (mirrors router6 accessTo / forwardRules):
config forwarding
    option src 'trusted'
    option dest 'transit'

config forwarding
    option src 'trusted'
    option dest 'app'

config forwarding
    option src 'trusted'
    option dest 'mgmt'

# Admin from management/INFRA can reach netmgmt for switch CLI etc.
config forwarding
    option src 'mgmt'
    option dest 'netmgmt'

# netmgmt → transit for outbound NTP/DNS only — no inbound from netmgmt
# to anywhere else. Network gear initiates updates; nothing needs to
# initiate connections *from* the switch into the rest of the network.
config forwarding
    option src 'netmgmt'
    option dest 'transit'

# ... etc ...

# APP-specific selective forwards to management:
config rule
    option name 'app -> basel ACME'
    option src 'app'
    option dest 'mgmt'
    option dest_ip '10.97.11.7'
    option dest_port '443'
    option proto 'tcp'
    option target 'ACCEPT'

# DNS/DHCP from any zone to BT8-gateway itself:
config rule
    option name 'Allow DNS/DHCP'
    option src '*'
    option dest_port '53 67 547'
    option proto 'tcp udp'
    option target 'ACCEPT'
    option limit '100/sec'
```

#### 6. Static routes for DMZ and `network` VLANs

No static routes required. BT8-gateway's connected routes are the
per-VLAN `/24`s for its own bridges (br-v11/12/20/21/50/99) — there
is no `10.97.0.0/16` aggregate. `network` (`10.91.0.0/16`) and DMZ
(`10.97.100.0/24` until end of Phase 5, then `10.91.100.0/24`) are
both covered by the default route via `10.255.255.1`. Verify with
`traceroute 10.97.100.41` from a BT8-gw-side host that the path is
`host → BT8-gw → 10.255.255.1 → thebeyond → langport`, and with
`ip route get 10.97.100.41` on BT8-gateway that the selected nexthop
is `10.255.255.1` via `br-v99`. If something unexpected (a stray
DHCP route option, manual misconfiguration) injects a `10.97.0.0/16`
aggregate, a more-specific `10.97.100.0/24 via 10.255.255.1 dev
br-v99` static route forces the right nexthop — but it shouldn't
be necessary.

#### 7. NTP, DNS resolver, and management

```uci
# /etc/config/system - chrony or ntpd against thebeyond
config system
    option timezone 'UTC'
    option hostname 'bt8gateway'

# ntpd — point at thebeyond's transit IP, not its network IP, so
# BT8-gateway never has to reach into the high-trust plane.
config timeserver 'ntp'
    list server '10.255.255.1'       # thebeyond NTP via transit
```

#### 8. Verify

```sh
# Routing table
ip route
ip -6 route
# Should see: default via 10.255.255.1 dev transit; per-VLAN /24s as connected.
# No /16 aggregate, so DMZ (10.97.100.0/24) and network (10.91.0.0/16) both
# follow the default via transit without needing a more-specific route.
# IPv6: per-VLAN ULA /64s as connected; default v6 route via
# fdc6:55f2:0a5e:ffff::1 dev br-v99.

# IPv6 (ULA-only baseline — no PD)
ip -6 addr show dev br-v99
# Should see only the static fdc6:55f2:0a5e:ffff::2/64 — no delegated
# prefix. If a delegated prefix appears, the ISP has enlarged the
# delegation and the plan should pivot to the GUA-enabled posture.

# From a host on APP, e.g.:
ping 10.91.10.1                  # thebeyond MGMT (via transit)
ping 1.1.1.1                     # internet egress through thebeyond NAT
traceroute 10.97.100.41          # langport (DMZ) - should hop through 10.255.255.1
                                 # via the default route (no /16 aggregate to short-circuit it).
                                 # (DMZ stays at .97.100 until end of Phase 5 renumbers it to .91.100)
```

### C. Manual setup: BT8 as office-side "dumb AP" (mesh-resident)

**Role:** mesh-resident access point. Joins `batman-adv` over `802.11s`,
broadcasts SSIDs for whatever zones the office side needs (typically
GUEST/IOT/GAME on the hostile side, plus a HOME/trusted SSID), tags
each SSID's frames into batman with the right VID. Pure L2 forwarding;
holds a single management IP on `network`/VLAN 10. No DHCP, no
firewall, no routing.

**Why VLAN 10 for management** (and not `netmgmt`/12): the AP is
mesh-resident, so its mgmt-traffic destination matters. Reaching
phantasma/thebeyond infra via `network`/10 takes one mesh hop
(AP → mesh → BT8-bridge → wire → thebeyond). Via `netmgmt`/12 it
would take two (AP → mesh → BT8-gw L3 → mesh → BT8-bridge →
thebeyond), violating the single-mesh-traversal invariant. See the
[placement principle](#network-device-placement-zero-or-one-mesh-hop).

**Assumptions:** OpenWrt 24.10+ flashed. Mesh PSK already in operator's
hands. Same package set as BT8-bridge (kmod-batman-adv, etc.).

#### 1. Initial setup, services off

Same shape as BT8-bridge §1–2: install packages, then disable
firewall/dnsmasq/odhcpd. The AP is L2-only — no services it can host.

#### 2. 802.11s mesh radio

Same as BT8-bridge §3: pick the 5GHz radio for `mesh0`, identical mesh
ID and PSK so it joins the existing fabric. `mesh_fwding 0` hands
forwarding to `batman-adv`.

#### 3. `batman-adv` virtual device

Like BT8-bridge but with only one hardif (`mesh0`) — no wired uplink:

```uci
config interface 'bat0'
    option proto 'batadv'
    option routing_algo 'BATMAN_V'
    option gw_mode 'off'

# Per-VLAN sub-devices on bat0 — one per SSID's tag, plus mgmt.
config device
    option name 'bat0.10'    # network — for our own mgmt
    option type '8021q'
    option ifname 'bat0'
    option vid '10'

config device
    option name 'bat0.30'    # untrusted (GUEST SSID)
    option type '8021q'
    option ifname 'bat0'
    option vid '30'

# Repeat for vid 40 (iot), 41 (game), and any trusted VID (e.g. 20).
```

#### 4. Management interface on `network`/VLAN 10

DHCP from thebeyond's Kea — phantasma and gateway resolve via
registry-derived DNS records once DHCP lands the lease.

```uci
config interface 'mgmt'
    option device 'bat0.10'
    option proto 'dhcp'
```

Reserve a `network.hosts.<ap-name>` entry in the registry (host ID
in 5–9 range — see network host-ID convention) and pin it via Kea
host-reservation so the address is stable.

#### 5. SSIDs bound to per-VLAN sub-devices

Each AP-mode `wifi-iface` is bound directly to its `bat0.<vid>` device
via a matching `network` block — that injects client frames into
batman tagged with the right VID. Repeat per SSID:

```uci
# Network record per VID — pure L2, no IP, no proto
config interface 'guest_l2'
    option device 'bat0.30'
    option proto 'none'
```

```uci
config wifi-iface 'guest'
    option device 'radio0'           # 2.4GHz client AP, for example
    option mode 'ap'
    option network 'guest_l2'        # tags frames into VID 30
    option ssid 'GuestNet'
    option encryption 'sae'
    option key '<GUEST_PSK>'
```

Repeat for IOT (vid 40), GAME (vid 41), HOME/trusted (vid 20), and any
others. The AP doesn't care which gateway terminates each VLAN — it
just tags and lets batman deliver.

#### 6. Verify

```sh
batctl if                            # mesh0 listed as the only hardif
batctl n                             # neighbours include BT8-bridge + BT8-gateway
ip -4 addr show dev bat0.10          # DHCP lease from thebeyond's Kea
ping 10.91.10.10                     # phantasma — confirms 1-mesh-hop path
ping 10.91.10.1                      # thebeyond MGMT
```

Connect a client to each broadcast SSID and confirm it gets the right
DHCP lease (from thebeyond for hostile zones, from BT8-gateway for
trusted zones) — the AP's tagging plus batman's delivery do all the
work.

### D. Reference: OpenWRT homelab L2 switch (out-of-flake)

**Role:** primary switch for homelab gear (VM hosts, NAS, etc.) wired
to BT8-gateway. Runs OpenWRT but is managed outside this flake; bringing
it into the flake is a non-goal of this plan. Listed here only so the
plan's network design accounts for its existence and the operator
knows what to update on the device once `netmgmt` is stood up.

**Requirements imposed by this plan:**

- **Management address on `netmgmt`/12.** Admin from the BT8-gw side
  hits 0 mesh hops on netmgmt; placing it on `network`/10 would force
  a 2-mesh-hop hairpin via thebeyond. See the
  [placement principle](#network-device-placement-zero-or-one-mesh-hop).
- **Trunk port to BT8-gateway** tagged for every VLAN the homelab
  needs (`management`/11, `netmgmt`/12, `lab`/21, `app`/50, plus
  others as services migrate). Native/untagged: nothing — keep all
  membership explicit.
- **Default route via BT8-gateway** (`10.97.12.1`) and DNS via
  thebeyond's transit address (`10.255.255.1`) — same upstream
  BT8-gateway itself uses.
- **No batman, no mesh.** Pure 802.1Q on a wire to BT8-gateway; the
  batman fabric terminates at BT8-gateway's per-VLAN bridges and
  becomes a plain VLAN trunk on the wire.

The switch's UCI is updated by the operator directly; the address it
ends up at on netmgmt is documented in the follow-up plan that brings
the switch into the flake (which will also add a `netmgmt.hosts` entry
for it). Until then, the switch is a known consumer of `netmgmt`/12
but has no registry entry.

### E. External security scan

**Role:** empirically verify, from outside our network, that
`thebeyond` exposes only the documented surface (three wireguard UDP
ports). Complements the Phase 0a eval-time WG-only assertion, which
proves the *config* is shaped right structurally — this runbook
proves the live ISP edge actually behaves accordingly (CPE quirks,
public-IP reachability, IPv6 if delegated, kernel/nftables actually
applying the policy as expected).

**When to run:**

- Phase 0b step 12 — first deploy of `thebeyond` as the gateway. **Required
  before declaring Phase 0 done.**
- Phase 3 deploy — trusted-zone migration. The largest single change
  to `thebeyond`'s zone topology in this plan; the rule re-derivation
  is the most plausible regression vector. Re-scan after deploy.
- After any change to `hosts/thebeyond/router.nix`'s `firewall` block
  or `external` zone definition (operator's call — phases that don't
  touch the external zone, like Phase 1 or Phase 5's APP service
  moves on the BT8-gateway side, can rely on the eval-time assertion
  + CI tests rather than re-running the live scan).

**Off-network position.** The scan must originate from outside our
network, not from inside any of our zones (an internal scan only
proves zone-to-zone policy, not WAN exposure). Two reasonable
positions:

- **Mobile hotspot** — laptop tethered to phone's cellular data,
  Wi-Fi disabled. Easiest; gives a residential-like external
  viewpoint. Use this for routine re-runs.
- **Short-lived VPS** — a $5/month VPS spun up just for the scan
  window, terminated after. Best for fully off-ISP scans (in case the
  cellular carrier and home ISP share infrastructure that masks
  something). Use for the Phase 0b initial scan.

**Inputs:**

- `WAN_V4` — `thebeyond`'s public IPv4 (read it off `dig +short
  myip.opendns.com @resolver1.opendns.com` from inside the network,
  or from `networkctl status wan` on `thebeyond`).
- `WAN_V6` — `thebeyond`'s WAN-interface global IPv6 if the ISP
  delegated anything beyond link-local (Phase 0b step 10's PD result
  determines whether this is in scope).

#### 1. TCP scan

```sh
# All-ports stealth check. -Pn skips host discovery (we know it's
# there); --max-retries 1 keeps the scan time bounded; -T3 is the
# default polite timing.
sudo nmap -sS -Pn -p- --max-retries 1 -T3 -oN /tmp/thebeyond-tcp.txt \
    "${WAN_V4}"
```

**Expected:** every port reports `filtered` (or the summary line
"All 65535 scanned ports on … are in ignored states. Not shown:
65535 filtered tcp ports"). No `open`, no `closed`. Anything else
is a finding.

If `WAN_V6` is reachable, repeat with `-6`:

```sh
sudo nmap -6 -sS -Pn -p- --max-retries 1 -oN /tmp/thebeyond-tcp6.txt \
    "${WAN_V6}"
```

#### 2. UDP scan (top 1000 + explicit WG ports)

```sh
# UDP is slow; scope to the top 1000 plus the WG ports we expect.
sudo nmap -sU -Pn --top-ports 1000 --max-retries 2 \
    -p "U:38506,59362,51820,T:" \
    -oN /tmp/thebeyond-udp.txt "${WAN_V4}"
# (the empty T: is just a guard against accidental TCP fall-through;
# the -sU flag is what controls the scan type.)
```

**Expected:**

- Wireguard ports (`38506`, `59362`, `51820`): `open|filtered`. WG
  silently absorbs unauthenticated packets, which nmap can't
  distinguish from filtered. This is correct.
- All other ports: `open|filtered` *or* `filtered`. **The disqualifier
  is `closed`** — that means the host responded with ICMP-port-
  unreachable, which would mean we're answering instead of dropping.
  Anything reporting `open` (a real UDP application replied) is a
  hard fail.

Repeat with `-6` against `WAN_V6` if applicable.

#### 3. ICMP

```sh
ping -c 5 -W 2 "${WAN_V4}"        # expect: 100% loss
ping6 -c 5 -W 2 "${WAN_V6}"       # expect: 100% loss (if applicable)
```

#### 4. Wireguard handshake (sanity-check the WG ports actually work)

A WG-keyed peer (operator's wg-vpn or wg-ba laptop) should still
complete a handshake against `WAN_V4:38506` (or 59362 / 51820 per
config). This is "we didn't accidentally lock ourselves out", not
part of the security verification proper.

```sh
# From the wg-keyed peer, against the relevant tunnel:
sudo wg-quick up wg-vpn
ping -c 3 10.91.10.1              # thebeyond's network gateway via tunnel
sudo wg-quick down wg-vpn
```

#### 5. Internal listening-socket spot-check

From an SSH session on `thebeyond` (post-deploy):

```sh
ss -tlnp | grep -vE '127\.0\.0\.1|\[::1\]'   # services bound externally
ss -ulnp | grep -vE '127\.0\.0\.1|\[::1\]'

# Should show only:
#   - wireguard UDP 38506 / 59362 / 51820 on the WAN-facing UDP socket
#     (or wildcard, since wireguard binds globally and the firewall
#     scopes exposure)
#   - kresd UDP/TCP 53 bound to internal bridges (brMGMT, brTRANSIT,
#     brDMZ, etc.) — *not* to 0.0.0.0 / [::]
#   - kea UDP 67 / 547 on the bridges it serves
#   - sshd TCP 22 (operator policy decides whether this is internal-
#     only or wildcard; record either way in the inventory)
```

Anything bound wildcard that isn't in the documented inventory is a
finding even if the firewall blocks it externally — defense-in-depth
prefers explicit bind-to-interface.

#### 6. Rendered ruleset review

```sh
nft list ruleset > /tmp/thebeyond-nft.txt
# Inspect the input chain on the external zone — should match the
# `inputRules` block in hosts/thebeyond/router.nix. The only accepts
# in the external→input path should be UDP 38506/59362/51820 plus
# whatever ICMPv6 ND/PMTUD the router6 module always installs.
grep -A 50 'chain.*input.*external' /tmp/thebeyond-nft.txt
```

Compare against `git show HEAD:hosts/thebeyond/router.nix` for the
expected accept set. Any extra accept rule is a finding to investigate
before declaring the scan passed.

#### 7. Record the result

Save the four scan outputs (`thebeyond-tcp.txt`, `thebeyond-tcp6.txt`,
`thebeyond-udp.txt`, `thebeyond-nft.txt`) to a private location with
the date and the deploy SHA. These are the audit artifacts — the
operator's own record that on $date, the live system exposed only the
documented surface. A follow-up investigation a year out will thank
past-you for keeping them.

## Resolved decisions

These started as open questions and have been settled; recorded here so the
reasoning is traceable from the plan rather than from the conversation log.

1. **Mesh L2 layer.** Keep `batman-adv` on top of `802.11s`. The
   VLAN-aware multipath behavior is exactly what carries
   GUEST/IOT/GAME-tagged client frames cleanly across mesh hops; pure
   `802.11s` would not.
2. **Mesh fleet replacement.** E8450 fleet is being replaced with BT8s
   (4/5 already removed; the last is optional). The Image Builder work in
   Phase 4 covers BT8 mesh-AP profiles in addition to BT8-gateway and
   BT8-bridge.
3. **`network` zone gateway location.** Stays on `thebeyond`. All
   networking devices reach each other on the L2 MGMT VLAN regardless,
   which is the actual operational requirement. Revisit if office-side
   diagnostics get awkward.
4. **`media` zone.** Stays on `thebeyond` — it's the wireguard endpoint
   for media-keyed devices. The current zone scope (allow GUEST-resident
   media-keyed devices to reach an HTPC like `oracion`) is unchanged.
   With the hostile-zone convergence decision, both the GUEST/untrusted
   client and the wg-media endpoint terminate on `thebeyond`, so the
   wireguard flow is entirely thebeyond-local — no transit hop. If we
   later want internal GUEST hosts to reach an HTPC *without* a
   wireguard handshake, that becomes a `untrusted → media` (or
   `untrusted → app`) forward rule on `thebeyond` itself, again with no
   transit hop.
5. **Transit VLAN sizing.** Special-case the registry to allow per-zone
   `prefixLength4` / `prefixLength6` (defaulting to `/24` and `/64`).
   Transit gets `/30` IPv4; IPv6 stays at default `/64` because the
   registry's `gateway6` formula plus the host ID for the BT8 side would
   land outside a `/127` carved at the natural boundary. See the
   registry-changes section above.
6. **CI/CD push path.** Punted. The image-pushing device will be a
   dedicated host separate from the saint-arkh job runners; we'll define
   its zone placement and forward rules when that plan lands. No new
   `dmz → network` relaxation in this plan.
7. **Phantasma lives on `network` (VLAN 10), not `management` (VLAN 11).**
   Phantasma is the recursive DNS resolver consumed by every router on
   the network. Routing depends on DNS, and routing infrastructure
   already lives on VLAN 10, so DNS belongs there too. This avoids a
   Phase-3 hairpin where `thebeyond`'s own DNS queries would otherwise
   traverse `transit → BT8-gateway → mesh` to reach a microVM
   physically hosted on `thebeyond` itself. The trade-off: `network`
   zone broadens from "AP/switch lockdown" to "router-adjacent
   infrastructure" and gains DNS input rules and an outbound path to
   `transit` for DNS replies. The other INFRA residents (tharbad,
   basel, messeldam, liberl, calvard, erebonia) are genuine
   infrastructure VMs/NAS and stay on `management`.
8. **Split IP space, per-gateway ownership.** Each gateway owns its own
   contiguous address space, on both IPv4 and IPv6:
   - `thebeyond` → `10.91.0.0/16` and `fdc6:55f2:0a5e:0000::/52`
   - `BT8-gateway` → `10.97.0.0/16` and `fdc6:55f2:0a5e:1000::/52`
   - `transit` → `10.255.255.0/30` and `fdc6:55f2:0a5e:ffff::/64` (third
     address space, neither gateway, instantly recognizable as the
     inter-gateway link in any routing table)

   Why both protocols: the long-form static-route table on `thebeyond`
   collapses from one entry per office-side `/24` (and `/64`) to a
   single `10.97.0.0/16 via 10.255.255.2` plus
   `fdc6:55f2:0a5e:1000::/52 via <bt8gw-transit6>`. The asymmetry of
   "v4 split, v6 unified" would be operationally confusing —
   routing-table aggregation that worked on one protocol but not the
   other would be a surprising read. The IPv6 split also fills a gap in
   the prior plan, which never spelled out cross-gateway ULA static
   routes; with aggregation, each side needs only one.

   The split removes the per-zone `bt8gw = 2` transition host-IDs that
   the shared-`/16` model needed (BT8-gateway holds `.1` from day one
   in its own space). Trade-off: a small number of hosts re-IP across
   prefixes — `phantasma` (Phase 0, into `10.91.10.0/24`) and
   `langport` + `trista` (Phase 5, into `10.91.100.0/24` when the rest
   of DMZ migrates to APP and the `10.97.100.0/24` subnet renumbers to
   thebeyond's space). Every BT8-gateway-side host *also* gets a new
   ULA address (e.g., `fdc6:55f2:0a5e:0014::<host>` →
   `fdc6:55f2:0a5e:1014::<host>` for HOME) but registry-derived, so
   DNS, `/etc/hosts`, and dnsmasq/odhcpd reservations regenerate
   automatically. ULA is internal-only (no GUA, no inbound v6) so the
   operational impact of the v6 churn is small.

   Resolved decision #5's `/64`-vs-`/127` wrinkle for transit IPv6
   stops mattering once transit lives in its own ULA slice: the host
   IDs (`::1`, `::2`) sit cleanly inside `:ffff::/64`, and the existing
   `mkHost` formula needs no special case.
9. **Hostile-zone convergence on `thebeyond`.** All hostile/untrusted
   zones — `dmz` (100), `untrusted`/GUEST (30), `adu` (31),
   `iot` (40), `game` (41) — terminate L3 on `thebeyond`'s router6
   stack. `BT8-gateway` carries them as L2-only batman passthrough
   (no IP, no fw4 zone, no DHCP) so SSIDs can still broadcast from the
   office BT8 APs. Access from a hostile zone to the homelab requires
   a wireguard tunnel (the `wg-media` zone is the prototype; `wg-iot`
   or similar can extend the same pattern when needed).

   **Trusted-side → hostile-zone access is governed by `transit`'s
   `forwardRules` on `thebeyond`.** A future Home Assistant instance
   on `iot` (40) is the load-bearing example: HOME hosts (humans) need
   to reach HA's web UI, the path is `HOME → BT8-gw → transit →
   thebeyond → iot`, and the policy lives on `thebeyond`'s `transit`
   zone (`forwardRules.iot` source-restricted to the trusted subnet).
   Concrete rules are in the [zone-wiring](#zone-wiring) section;
   tighten to specific HA host + ports when HA lands on the registry.

   Why: one source of truth for hostile-traffic policy, on the
   more-mature firewall (router6 nftables vs. fw4). The
   `untrusted → trusted` boundary is the most security-sensitive in
   the network; consolidating it on a single firewall avoids the risk
   of a fw4 misconfiguration leaking traffic that the router6 zone
   model would have caught. Also a topology win: hostile-zone
   internet egress goes directly to thebeyond's NAT without a transit
   hop, and inter-hostile-zone flows (e.g., `wg-media → oracion` once
   oracion is on APP, or future `wg-iot → home-assistant`) are
   thebeyond-local once the `media`/`app` endpoints converge there too.

   Cost: BT8-gateway's manual config gets four extra L2-only bridges
   (br-v30/31/40/41) beyond the obvious DMZ passthrough. Cheap.
10. **Single-mesh-traversal invariant.** Gateway placement must not
    force any device's traffic to traverse the wireless mesh more than
    once per direction. Wireguard encapsulation is the lone exception:
    a tunneled flow logically traverses the mesh once for the encrypted
    path and once for the decrypted path, but since both endpoints are
    nodes that need wireless connectivity anyway, the architecture
    introduces no extra hops beyond what the topology already requires.

    Why: wireless mesh hops cost latency and bandwidth on a shared
    medium; doubling them would compound on every cross-zone flow.
    This invariant is the load-bearing reason hostile zones terminate
    on `thebeyond` rather than on `BT8-gateway` — putting them on
    `BT8-gateway` would force IoT/GUEST/GAME internet egress to mesh
    out (client → BT8-gw L3) and then mesh back (BT8-gw → BT8-bridge →
    thebeyond NAT), which violates the invariant in the inbound
    direction.

    How to apply: when adding a new zone, ask "is the path
    `client → AP → batman → L3 gateway → batman → destination` capped
    at one batman traversal in each direction?" If not, the gateway
    placement is wrong. The IP-space split also makes this easy to
    audit visually — addresses telegraph which gateway will terminate
    each flow.

## Risks

- **Coordinated cutover (Phase 0b + Phase 3).** Both involve simultaneous
  changes on multiple devices; a misconfiguration leaves us locked out.
  Mitigation: deploy-rs `magic_rollback` for `thebeyond`; serial console
  available for BT8-gateway; explicit recovery steps in the cutover
  runbook. Phase 0a is a pure code/test phase to shake out config errors
  before the hardware swap.
- **`thebeyond` as a single point of failure (post-Phase-0b).** Pre-plan,
  the existing BT8 was a single-box gateway (already a SPOF). Post-plan,
  `thebeyond` takes that role for everything that crosses a trust
  boundary, plus the WAN edge. If `thebeyond` hardware fails, the entire
  household loses internet and inter-zone routing; same-VLAN, same-side
  flows still work. No automated failover by design — recovery is a
  hardware swap or temporary fallback. Mitigations to consider (out of
  scope for this plan): keep the BT8-bridge image with a "fallback
  gateway" UCI snapshot stashed off-device for emergency restore;
  document the manual sequence to re-arm a BT8 as a temporary
  single-box gateway if `thebeyond` is down for >a few hours.
- **DHCP migration (Phase 3).** Clients with active leases at the moment
  of migration may end up with stale gateways. Mitigation: shorten lease
  time on migrated VLANs in the days leading up, then bump back after.
- **IPv6 PD size is `/64`** (verified by the operator against the
  existing gateway). The plan baseline is already
  [ULA-only internal IPv6](#ipv6) with IPv4 NAT for all WAN, so this
  isn't a risk to Phase 0–5 — it's a deferred-feature note.
  Inbound IPv6 (`ipv6-gua-stable-ingress`) waits on the ISP enlarging
  the delegation; HE tunnel and NPTv6 remain documented options if
  GUA ingress becomes urgent before that happens.
- **fw4 vs nftables drift.** Two firewall engines mean every zone change
  has to be reflected twice until Phase 4 ships. Mitigation: keep the
  manually-maintained period short; aim for Phase 4 within ~1 month of
  Phase 3.
- **Mesh "fat pipe" throughput and reliability.** Inter-gateway traffic
  traverses the `802.11s` mesh between `BT8-bridge` (modem closet) and
  `BT8-gateway` (office). A wired run between the two locations is
  infeasible, so the mesh is the committed inter-gateway path; the
  network is designed to operate over it as a hard requirement, not as
  a fallback. Implications:
  - If the mesh saturates (e.g., during NAS backups across zones),
    cross-zone routing performance suffers. Bandwidth-heavy flows that
    can stay on one side of transit (e.g., NAS backups within the
    office) should be designed to do so.
  - If the mesh degrades or drops, all cross-gateway flows fail:
    office-side internet egress (NAT lives on `thebeyond`), DMZ
    reachability from APP/HOME/etc., RA/DHCPv6-PD propagation to
    office-side VLANs, and `thebeyond ↔ phantasma` *only* if phantasma
    moves out of the modem-closet L2 segment (it doesn't —
    phantasma stays a microvm on `thebeyond`, reachable directly via
    `brMGMT` regardless of mesh state).
  - Same-VLAN, same-side traffic continues to work during a mesh
    outage (HOME ↔ HOME, INFRA ↔ INFRA on the office side; phantasma
    ↔ thebeyond in the modem closet).
  - Mitigation: monitor mesh quality (RSSI, batman-adv throughput
    counters); place the two BT8s with line-of-sight or near-LOS
    separation; keep mesh-encryption settings aligned with what the
    radios can sustain at the chosen distance.
