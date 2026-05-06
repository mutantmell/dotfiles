# Dual-Gateway + APP VLAN Migration Plan

**Status:** Drafted (not started)
**Last updated:** 2026-05-06
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
- Migrating `glorious` (ADU) routing. ADU keeps its current model.
- Headscale, IPv6 GUA stable ingress, and other in-flight zone work
  (covered by their own plans). Where they touch the same files, this plan
  notes it but does not subsume them.

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
                            │  app, mgmt,     │
                            │  trusted, lab,  │  + 802.11s mesh node
                            │  untrusted...   │  + AP radios (clients)
                            └──┬──────────────┘
                               │ wired (trunk, plain 802.1Q — not batman)
                               │
                              arseille (managed switch) ─── homelab gear

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
wired side toward `arseille` is a plain 802.1Q trunk — `arseille` does
not speak batman. The batman fabric terminates at the per-VLAN bridges
inside `BT8-gateway`.

### Routing model

- **NAT**: only on `thebeyond` (single egress point).
- **Default route**:
  - `thebeyond`: out the WAN.
  - `BT8-gateway`: out the **transit** VLAN to `thebeyond`'s transit address.
- **Static routes on `thebeyond`**: the office-side `/24`s (APP, INFRA,
  trusted, lab, untrusted, IOT, GAME) reach via transit VLAN to
  `BT8-gateway`.
- **Static routes on `BT8-gateway`**: DMZ (`10.97.100.0/24`) and network
  (`10.97.10.0/24`) reach via transit VLAN to `thebeyond`. Default route also
  via `thebeyond`.
- **DMZ passthrough**: DMZ VLAN is L2-bridged across the mesh through
  `BT8-gateway`, but `BT8-gateway` has *no IP* on DMZ. DMZ frames are
  transparently forwarded to/from `thebeyond` where the DMZ gateway lives.
- **Transit VLAN passes through `BT8-bridge`**: like every other VLAN,
  the transit VLAN (99) is carried as `bat0.99` across the batman
  fabric. `BT8-bridge` participates in transit only as a passthrough
  L2 bridge with no IP on it; the actual `/30` peers are `thebeyond`
  (.1) and `BT8-gateway` (.2).
- **Asymmetric routing for `network ↔ office-side-zone` is expected
  and benign.** The `network` (MGMT) VLAN keeps its gateway on
  `thebeyond` while client-zone gateways move to `BT8-gateway`. A DNS
  query from a HOME host to `phantasma` (now on `network`) takes
  these paths:
  - **Forward:** `HOME-host → BT8-gateway` (its default GW, since
    `network` is a different subnet) `→ br-v10` (BT8-gateway has a
    directly-connected route, since it holds an IP on `network`)
    `→ bat0.10 → mesh → BT8-bridge → wired → bat0.10 →` phantasma.
    No transit hop on the forward direction.
  - **Reverse:** `phantasma → thebeyond` (default GW for `network`,
    since HOME is a different subnet) `→ static route 10.97.20.0/24
    via 10.97.99.2 → brTRANSIT → mesh → BT8-gateway → br-v20 →`
    HOME-host. The reverse traverses `transit`.

  This works because `BT8-gateway` sees *both* directions of the flow
  (forward in `br-v20`/out `br-v10`; reverse in `br-v99`/out `br-v20`),
  so conntrack state on `BT8-gateway` matches and `ct state
  established,related accept` covers the reverse without an explicit
  rule. `thebeyond` sees only the reverse direction, originating from
  `phantasma → transit`. The `network` zone's outbound rules (added
  below) explicitly allow phantasma's DNS responses to leave via the
  `transit` zone, so the firewall passes it without depending on
  forward-direction state. The asymmetry is therefore operationally
  fine.

  Cross-zone forwards that originate on `thebeyond`'s side
  (`network → trusted`, etc.) similarly route via transit in both
  directions and remain symmetric end-to-end.

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
| `trusted`      | `BT8-gateway`  | dnsmasq + odhcpd    | no  |
| `lab`          | `BT8-gateway`  | dnsmasq + odhcpd    | no  |
| `untrusted`*   | `BT8-gateway`  | dnsmasq + odhcpd    | no  |
| `media`        | `BT8-gateway`  | (wg-keyed only)     | no  |

(BT8-gateway DHCP is dnsmasq for v4 + odhcpd for v6/RA, configured under
the unified OpenWrt `/etc/config/dhcp` UCI tree.)

\* `untrusted` here covers GUEST, IOT, GAME. ADU (`untrusted` zone, VLAN 31)
stays with `glorious` per current setup; routing for it is unchanged.

## Network registry changes

### Move phantasma from `management` (INFRA) to `network` (MGMT)

`phantasma` is the recursive DNS resolver and is consumed by every router on
the network — both `thebeyond` (`router6.dns.upstream`) and `BT8-gateway`
(dnsmasq forwarder). Routing depends on DNS, and routing infrastructure
lives on VLAN 10 (`network` zone), so phantasma belongs there too. Keeping it
on INFRA created a Phase-3 hairpin where `thebeyond`'s own DNS queries had to
traverse `transit → BT8-gateway → mesh` to reach a microVM physically hosted
on `thebeyond` itself.

After the move:
- `thebeyond` reaches phantasma directly across `brMGMT` (10.97.10.1/24
  stays on `thebeyond` per resolved decision: `network` gateway location).
- `BT8-gateway` reaches phantasma directly across its `network`-bound
  interface — same L2 segment, no L3 hop.
- The microvm bridge in `hosts/thebeyond/router.nix`
  (`systemd.network.networks."10-vm-infra"`) needs to retarget to `brMGMT`
  for phantasma's tap; INFRA-resident microvms (none today, but the
  pattern remains) keep targeting `brINFRA`. A pure rename or a per-VM
  match is fine — operator's call.

Registry change: in `lib/common/data/network.nix`, move
`phantasma = 2` from `management.hosts` to `network.hosts` (host ID 2 stays
free in `management`). DNS records, `/etc/hosts`, and egress rules
regenerate from the registry, so no other call-site changes are required.

### New zones

Two new zones in `lib/common/data/network.nix`:

```nix
app = {
  vlanId = 50;            # picked: between LAB (21) and DMZ (100)
  hosts = {};             # populated as services migrate
};
transit = {
  vlanId = 99;
  prefixLength4 = 30;     # special-cased: point-to-point /30
  # IPv6 stays at the default /64. We could shrink to /127 per RFC 6164
  # for a cleaner PtP model, but the registry's gateway6 formula
  # (`...:63::1`) plus a hostId of 2 yields `...:63::2`, which would fall
  # outside a /127 carved at `...:63::0/127`. Keeping /64 avoids the
  # off-by-host-id math without losing anything operationally.
  hosts = {
    thebeyond-transit = 1;     # 10.97.99.1
    bt8gw-transit = 2;         # 10.97.99.2
  };
};
```

The registry needs a small extension to honor per-zone prefix lengths
instead of hard-coding `/24` and `/64`. Existing call sites already read
`prefixLength4` / `prefixLength6` from the network record (those fields
exist today, just always set to the defaults), so the change is localized
to `rawNetworks` enrichment in `network.nix`:

```nix
networks = lib.mapAttrs (_: net:
  net // {
    subnet4 = "${ipv4Prefix}.${toString net.vlanId}.0/${toString (net.prefixLength4 or 24)}";
    subnet6 = "${ulaPrefix}:${vlanHex net.vlanId}::/${toString (net.prefixLength6 or 64)}";
    prefixLength4 = net.prefixLength4 or 24;
    prefixLength6 = net.prefixLength6 or 64;
    gateway4 = "${ipv4Prefix}.${toString net.vlanId}.1";
    gateway6 = "${ulaPrefix}:${vlanHex net.vlanId}::1";
  })
  rawNetworks;
```

`mkHost` currently hard-codes `/24` and `/64` in `subnet4`/`subnet6`/`cidr4`/`cidr6`.
It needs to take the network record (or its prefix lengths) so the values
flow through. The `hostRangeCheck` validation should also become
prefix-length-aware (`hostId` must fit in `2^(32-prefixLength4) - 2`).

### BT8-gateway transition host IDs

Each migrated zone needs a `bt8gw` entry in `hosts` so BT8-gateway can
hold a real registry-allocated IP during Phase 2 testing (when `.1` is
still owned by `thebeyond`). Pattern mirrors `bt8gw-transit = 2`:

```nix
app.hosts.bt8gw        = 2;   # 10.97.50.2
management.hosts.bt8gw = 2;   # 10.97.11.2 (phantasma vacates .2 in Phase 1)
trusted.hosts.bt8gw    = 2;   # 10.97.20.2
lab.hosts.bt8gw        = 2;   # 10.97.21.2
untrusted.hosts.bt8gw  = 2;   # 10.97.30.2 (GUEST)
iot.hosts.bt8gw        = 2;   # 10.97.40.2
game.hosts.bt8gw       = 2;   # 10.97.41.2
```

These IPs let BT8-gateway route real client traffic during Phase 2 (test
clients receive DHCP with `default GW = .2`) and serve as a stable
secondary address through the cutover. At the Phase 3 cutover moment,
BT8-gateway adds `.1` as a *secondary* address while `thebeyond` drops
`.1` — `.2` keeps working through the flap. Drop `.2` post-cutover or
keep it as a permanent diagnostic address (operator's call).

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
    # Now: "router-adjacent infrastructure" — phantasma (DNS) lives here,
    # so the zone needs DNS in/out and outbound to office-side zones for
    # DNS responses (which leave via the transit zone after Phase 3).
    #
    # Note: `accessTo = [ "transit" ]` is broader than just phantasma's
    # DNS replies — it permits any `network → transit` forward. That's
    # operationally fine while `network` is sparse (only phantasma plus
    # APs/switches), but if `network` grows, tighten to a
    # `forwardRules.transit = [ ...phantasma DNS source-restricted... ]`
    # list and drop the broad `accessTo`.
    icmpEcho = "enable";
    accessTo = [ "transit" ];   # phantasma's DNS replies to office-side
                                # clients leave via transit
    inputRules = [
      { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
      # DNS to phantasma (input rule allows traffic *to* the resolver
      # from anywhere on the same L2 segment; cross-zone DNS arrives at
      # phantasma via the forward chain, governed by accessTo above).
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
    accessTo = [ "external" "ba-tunnel" ];   # dmz handled via explicit
                                              # forwardRules below
    inputRules = [];        # no router services on the transit interface

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
  };
};
```

**NAT verification.** `transit → external` relies on the existing NAT rule
matching on egress interface (`oifname == external_iface`) without gating
on source zone. Verify in `modules/router6/firewall.nix` that the
masquerade rule applies to any forwarded flow, not only flows from
specific source zones. If it gates on source, extend it to include
`transit`.

`thebeyond`'s existing `dmz`, `ba-tunnel`, `external` zones stay as they
are. The `network` zone's character changes (see above) — what was
"AP/switch lockdown" becomes "router-adjacent infrastructure", which
includes phantasma. Importantly, the office-side zones (`management`,
`trusted`, `lab`, `untrusted`) are **removed from `thebeyond`'s zone list**
in Phase 3 when their gateways move — they become `BT8-gateway`'s problem.
(Until that phase, they remain on `thebeyond`.)

On `BT8-gateway` (OpenWrt fw4 zone semantics, named to mirror router6):

| fw4 zone     | networks bound        | input    | forward | masq | output |
|--------------|-----------------------|----------|---------|------|--------|
| `transit`| `transit` interface   | REJECT   | REJECT  | no   | ACCEPT |
| `app`        | APP VLAN (50)         | REJECT   | REJECT  | no   | ACCEPT |
| `management` | INFRA VLAN (11)       | ACCEPT (services as needed) | REJECT | no | ACCEPT |
| `trusted`    | HOME VLAN (20)        | ACCEPT   | REJECT  | no   | ACCEPT |
| `lab`        | LAB VLAN (21)         | ACCEPT (services) | REJECT | no | ACCEPT |
| `untrusted`  | GUEST/IOT/GAME VLANs  | REJECT (DNS/DHCP only) | REJECT | no | ACCEPT |

Forward rules between zones are configured per-pair in OpenWrt's
`firewall.@forwarding[…]` UCI, mirroring the router6 `accessTo` semantics:
- `trusted → app, management, lab, untrusted, transit` (mirrors current
  trusted `accessTo`).
- `lab → management, lab, transit`.
- `untrusted → transit` only.
- `app → transit` and selective forwards to `management` (mirrors what
  DMZ has on `thebeyond` today: ACME, Loki, Authelia OIDC).
- `management → management, trusted, untrusted, app, transit` (mirrors
  current management `accessTo`).

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

Steps:
1. **Pre-flight: confirm BT8 hardware support in the chosen OpenWrt
   release.** Asus ZenWiFi BT8 is expected to land on `mediatek/filogic`
   (MT7988A SoC), but verify against the OpenWrt support matrix for the
   release we'll actually pin (`openwrt-hashes.json` `defaultRelease`).
   Confirm device-tree, switch driver, and wireless driver all work on
   the chosen build before flashing either of the two BT8s. If support
   is incomplete or unstable, hold the plan until a release lands —
   manual UCI on a half-supported image is a long, painful debug loop.
2. **Pre-flight: enable PD client on thebeyond's WAN.** The current
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

3. **Drop `bond0` from `thebeyond`'s topology** before first deploy. The
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

   Stage `nixos-anywhere` from a build that includes both the bond0
   removal *and* the existing 9-zone configuration so the first boot
   comes up with a working router. Deploy `thebeyond` with **no other
   router config changes yet** — APP/transit are added in Phase 1, so
   the existing zones still gate everything on `thebeyond`.
4. Physically move `thebeyond` to the modem closet. Connect WAN to modem.

   **Physical location of BT8-bridge (the current production BT8) — also
   resolved in this step.** The architecture diagram puts BT8-bridge
   alongside `thebeyond` in the modem closet so the inter-device wired
   link is a short cable, with the 802.11s "fat pipe" handling the long
   hop from modem closet to office. Two cases:
   - *If the current production BT8 is already in the modem closet*
     (alongside the modem), no physical move is required — leave it in
     place, just connect `thebeyond`'s wired NIC to one of its LAN
     ports.
   - *If the current production BT8 is in the office today*, relocate
     it to the modem closet during this same maintenance window (no
     extra outage — the network is already down for the cutover) so it
     ends up next to `thebeyond`. The mesh leg from BT8-bridge to the
     remaining office BT8s now runs over 802.11s; verify that mesh
     quality (RSSI, batman throughput counters) is acceptable from the
     new location before declaring the cutover successful, since this
     mesh is the committed inter-gateway path post-Phase-3 (see
     [Risks: mesh fat pipe](#risks)).

   **Bootstrapping note.** `thebeyond`'s NIC is `bat0`'s hard interface
   from first boot, so the cable carries batman frames. The current
   production BT8 doesn't speak batman on its wired port yet, so the
   link is dead between step 4 and step 5. **During this gap the entire
   household loses internet egress and inter-VLAN routing**: NAT lives
   on `thebeyond`, and the office-side mesh has no path to it until the
   current BT8 is reconfigured into the wireless-bridge role. Same-VLAN,
   same-side traffic continues to work (the office mesh stays internally
   connected over `802.11s`), but everything else is offline. Execute
   steps 4 and 5 in close succession with the operator on-site at both
   devices, and schedule the cutover in a maintenance window
   (announce/expect ~10–30 min of internet downtime, +relocation time
   if the BT8 is moving rooms).
5. Reconfigure the current production BT8 (manually):
   - Remove its WAN interface (no longer the gateway).
   - Make it a "dumb AP" / wireless-bridge (effectively the
     [BT8-bridge config](#a-manual-setup-bt8-as-dumb-ap--wireless-bridge)).
   - Disable its firewall, NAT, DHCP server.
   - Keep its 802.11s mesh and AP radios so other office BT8s still
     associate.
   - Give it a single management IP on `network` VLAN.
6. Cutover: bring up `thebeyond`'s WAN; verify NAT, DHCP, DNS, internet
   reachability from each existing zone.
7. **Sanity-check IPv6 delegation size.** On `thebeyond`:

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

8. The current production BT8 is now physically a dumb-AP-with-mesh. Going
   forward, we'll call this device **BT8-bridge**.

After Phase 0: single-gateway model on new hardware in the right physical
locations, with IPv6 delegation size known and downstream plan adjusted
accordingly.

### Phase 1 — Add APP and transit VLANs to the registry and `thebeyond`

**Goal:** plumbing for the new zones in place, no production traffic on them
yet.

Steps:
1. **Extend the registry to honor per-zone prefix lengths.** In
   `lib/common/data/network.nix`:
   - Update `rawNetworks` enrichment so `subnet4`/`subnet6`/`gateway4`/
     `gateway6`/`prefixLength4`/`prefixLength6` derive from `net.prefixLength4
     or 24` and `net.prefixLength6 or 64` (snippet in the [registry-changes
     section](#new-zones)). Today these fields are computed but always set
     to the defaults at lines 168–169 of `network.nix`.
   - Refactor `mkHost` (currently `zoneName: vlanId: hostId`) to also receive
     prefix lengths, so `subnet4`/`subnet6`/`cidr4`/`cidr6` use the per-zone
     values instead of the hard-coded `/24`/`/64` at lines 180–183. The
     simplest shape is `mkHost = zoneName: net: hostId:` and have the `hosts
     =` flatten at line 187 pass the network record in.
   - Make `hostRangeCheck` (line 134) prefix-aware: `id` must be in
     `1..(2^(32 - prefixLength4) - 2)` rather than `1..254`. The transit
     `/30` then validates host IDs 1 and 2 correctly.
   - Add a pure-eval test under `tests/lib/` that exercises a non-default
     prefix length (transit `/30` is the natural fixture).
2. Add `app` (VLAN 50, default prefixes) and `transit` (VLAN 99,
   `prefixLength4 = 30`) to `lib/common/data/network.nix`.
3. Add corresponding `mkVlanBridge` entries in `hosts/thebeyond/router.nix`
   for both VLANs. APP gets a thebeyond-side gateway IP for now (will move
   to BT8-gateway in Phase 2 once BT8-gateway is online); transit gets
   `10.97.99.1/30` (point-to-point — registry now models it correctly).
4. Add `app` and `transit` zones to `router6.zones`. Conservative defaults:
   APP behaves like DMZ (no `accessTo`, restricted egress, selective forwards
   to management services); transit accepts ICMP and nothing else.
5. Update `lib/common/data/openwrt.nix` `switchVlans` to add APP and transit
   tags so `arseille` (the managed switch in the office, between
   BT8-gateway and the homelab gear) trunks them.

   *(Pre-Phase-1 cleanup, already staged uncommitted: drop the
   `MEDIA = {tag = 42;}` entry from `switchVlans` — there is no media VLAN;
   the `media` firewall zone exists only to gate what `wg-media` peers can
   reach, and the stale switch tag was misleading. Commit this as a
   standalone change before starting Phase 1.)*
6. Rebuild and redeploy `arseille` and `thebeyond` (deploy-rs with magic
   rollback for `thebeyond`).

   **Arseille reflash risk.** Adding VLANs to `arseille` requires a
   sysupgrade flash, which drops the homelab off the network for the
   duration of the reflash + reboot (~1–2 minutes). The outage is
   homelab-only — `thebeyond`, `BT8-bridge`, the BT8 mesh, and clients
   not behind `arseille` are unaffected — and is acceptable per
   operator confirmation. Mitigation options:
   - Schedule the reflash during a low-traffic window.
   - **Or** add the new VLAN tags via runtime UCI on `arseille` first
     (no flash, just a reload), confirm trunking works end-to-end,
     *then* bake the tags into the next image rebuild so the runtime
     state matches the declared state. This avoids the outage entirely
     during Phase 1 at the cost of a small drift window.
7. **Migrate phantasma from `management` (INFRA) to `network` (MGMT).**
   This move is independent of the dual-gateway cutover but lands
   cleanly here: it changes phantasma's IP from `10.97.11.2` to
   `10.97.10.2` and reattaches the microVM tap to `brMGMT` instead of
   `brINFRA`. Concretely:
   - Move `phantasma = 2` in `lib/common/data/network.nix` from
     `management.hosts` to `network.hosts`.
   - **Rename phantasma's microvm tap from `vm-11-phantasma` to
     `vm-10-phantasma`** in
     `hosts/thebeyond/microvm/guests/phantasma/microvm.nix` (the
     `microvm.interfaces[].id` field). The current tap name embeds
     VLAN 11 by convention, and the rename keeps the convention
     consistent with phantasma's new VLAN.
   - **Update phantasma's MAC** in the same file from
     `5E:11:AD:01:00:02` to `5E:0A:AD:01:00:02`. The second octet
     encodes the VLAN ID in hex (`0x0A` = 10) per existing convention;
     the last octet (`02`) keeps phantasma's host ID unchanged.
   - Replace the existing `systemd.network.networks."10-vm-infra"` rule
     in `hosts/thebeyond/router.nix` with a `10-vm-network` rule that
     matches `vm-10-*` and bridges to `brMGMT`, and keep the existing
     `vm-11-*` → `brINFRA` rule for any future INFRA-resident microvms.
   - Add `udp/tcp dport 53` and `udp dport 123` (NTP) input rules to
     the `network` zone in `router6.zones` (per the [zone wiring
     section](#zone-wiring)), and add `accessTo = [ "transit" ]` so
     phantasma's DNS replies to office-side clients pass forward
     policy after Phase 3.
   - Update phantasma's microvm config (if it pins its own IP) to
     `10.97.10.2`. Otherwise the registry-derived helpers
     (`mkExtraHosts`, `mkUnboundLocalData`) regenerate automatically.
   - Verify: from `thebeyond`, `dig @10.97.10.2 phantasma.internal`
     succeeds; from a HOME client, the same query through BT8-gateway's
     dnsmasq forwarder succeeds (note: at this point BT8-gateway
     doesn't exist yet, so this verification step waits until Phase 2).
8. Smoke test: stand up a throwaway VM on APP VLAN, confirm DHCP, DNS,
   internet egress.

After Phase 1: APP and transit exist; phantasma is on its final IP
(`10.97.10.2`). APP is gatewayed by `thebeyond`. Hosts can be migrated
into APP one-by-one without depending on Phase 2/3.

### Phase 2 — Manual proof: BT8-bridge and BT8-gateway

**Goal:** prove the dual-gateway routing/firewall model on a single VLAN
(start with APP) using BT8-gateway. No production cutover.

Steps:
1. Configure BT8-gateway by hand using the
   [BT8-gateway manual setup](#b-manual-setup-bt8-as-secondary-gateway). For
   this phase, only configure APP VLAN and transit VLAN — leave other VLANs
   for Phase 3.
2. On `thebeyond`, add a static route: `10.97.50.0/24 via 10.97.99.2 dev
   brTRANSIT`. The router6 module does not currently expose a static-route
   option, so this phase introduces one:

   ```nix
   # modules/router6/default.nix — new top-level option
   router6.routes = mkOption {
     type = types.listOf (types.submodule {
       options = {
         destination = mkOption { type = types.str; };  # "10.97.50.0/24"
         gateway     = mkOption { type = types.str; };  # "10.97.99.2"
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

   Translation to systemd-networkd is mechanical — group routes by
   `interface`, emit them under the corresponding network's `routes = [
   { Route = { Destination = ...; Gateway = ...; Metric? = ...; }; } ]`
   list in `modules/router6/networking.nix`. A pure-Nix evaluation test
   (`tests/lib/router6-routes.nix`) asserts the generated config for a
   representative `routes` declaration. By Phase 3, the office-side
   subnets are configured the same way — one entry per migrated VLAN.
3. Remove `thebeyond`'s gateway IP from the APP VLAN bridge — the APP
   gateway is now BT8-gateway. Keep the bridge as a member-only bridge so
   the L2 trunks correctly to the mesh.
4. On BT8-gateway, configure DHCP for APP VLAN (odhcpd). Connect
   a test device to APP VLAN (via `arseille` access port or directly via
   wifi if a test SSID is bound to APP).
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
   - Test device reaches `phantasma` (network) — directly reachable
     across the L2 mesh since BT8-gateway holds an IP on the `network`
     subnet. Confirm DNS resolution succeeds end-to-end.
   - Test device → DMZ host (e.g., `langport`): traffic must flow
     APP-host → BT8-gateway → transit → `thebeyond` → DMZ. Confirm via
     `traceroute` and `tcpdump` on the transit VLAN.
6. Document any UCI snippets or kernel-tuning that turned out to be needed
   in the [Phase 4 implementation notes](#phase-4--codify-bt8-gateway-and-bt8-bridge-in-image-builder).

After Phase 2: we know the model works for one VLAN. Manual config exists on
BT8-gateway but is not yet image-built.

### Phase 3 — Production cutover of office-side VLAN gateways

**Goal:** move all office-side VLAN gateways from `thebeyond` to BT8-gateway.

Steps:
1. Physically install BT8-gateway in its production location in the office.
2. On BT8-gateway (manually, building on Phase 2 config), add the remaining
   office-side VLANs: INFRA (11), HOME (20), LAB (21), GUEST (30), IOT (40),
   GAME (41). For each: bridge, **`.2` interface IP** (bt8gw transition
   address per registry), odhcpd, fw4 zone binding. Crucially, BT8-gateway
   does *not* hold `.1` yet — `thebeyond` keeps the gateway IP through this
   step.
3. **DHCP cutover** (per VLAN; can be done all-at-once or one-VLAN-at-a-time).
   Order of operations avoids any no-DHCP gap and any double-DHCP race:

   a. **Bring up DHCP on BT8-gateway** with a narrow, non-overlapping pool
      (e.g., `.240–.249`) and gateway = `.2` (BT8-gateway's actual IP at
      this point). Verify a test client gets a working lease and routes
      through BT8-gateway end-to-end (test confirms real routing, not just
      lease-serving, because BT8-gateway holds `.2` for real).
   b. **Stop Kea on `thebeyond` for the migrated VLAN(s)** (leave Kea up
      for `dmz`, `network`, and any unmigrated VLANs).
   c. **Expand BT8-gateway's pool** to the full registry-allocated range
      (e.g., `.100–.199`), still serving gateway = `.2`.
   d. Wait for existing clients to renew, or bounce DHCP on stragglers
      (`dhclient -r && dhclient` / `nmcli connection up <conn>`). Existing
      `.1` leases keep working — `.1` is still on `thebeyond` and routing
      through `thebeyond` still works for now.

   The two DHCP pools must not overlap during the verification window or
   two servers will hand out conflicting leases.

4. **Gateway-IP flip** (per VLAN). With both gateways' DHCP-served paths
   working through BT8-gateway, swap the `.1` ownership:

   a. Add `.1` to BT8-gateway's bridge as a secondary address (now holds
      both `.1` and `.2`). Brief — this is the only window where both
      devices respond to ARP for `.1`.
   b. Within seconds, remove `.1` from `thebeyond`'s bridge for that VLAN.
      Existing leases pointing at `.1` continue to route — `.1` is now on
      BT8-gateway. Expect a brief ARP cache flap on clients.
   c. Update BT8-gateway's DHCP to serve gateway = `.1` going forward.
      New leases get the canonical address; existing leases keep working
      until renewal.
   d. (Optional, post-stability) Drop `.2` from BT8-gateway, or leave it
      as a permanent secondary diagnostic address.

   **Compress the dual-`.1` window.** Steps 4a–4b should run as a single
   scripted SSH sequence rather than two manual operator actions, so the
   window where both devices respond to ARP for `.1` is sub-second
   instead of "as long as it takes the operator to switch terminals".
   The script should also send a gratuitous ARP from BT8-gateway after
   the takeover so client ARP caches converge on the new MAC without
   waiting for a natural refresh. Sketch:

   ```sh
   # Run from operator workstation; substitute <vlan>, <iface> per VLAN.
   ssh root@bt8-gateway "ip addr add 10.97.<vlan>.1/24 dev br-v<vlan>" && \
   ssh root@thebeyond  "ip addr del 10.97.<vlan>.1/24 dev brV<vlan>"  && \
   ssh root@bt8-gateway "arping -c 3 -A -I br-v<vlan> 10.97.<vlan>.1"
   ```

   `arping -A` (gratuitous ARP, sender = target) is the standard way to
   announce an IP→MAC change on a shared L2.

5. Apply on `thebeyond`:
   - Remove the gateway IPs from the bridges for migrated VLANs. Keep
     the bridges (they exist purely as the `bat0.<tag>` termination on
     `thebeyond`'s side of the batman fabric — without them, frames
     for those VLANs have nowhere to land on `thebeyond`). Just drop
     the `addresses` and `dhcp.enable` from the bridge's network block.
   - Add static routes for each migrated `/24` via transit to BT8-gateway
     using the `router6.routes` option introduced in Phase 2.
   - Remove the migrated zones (`management`, `trusted`, `lab`,
     `untrusted` *for the moved VLANs*) from `router6.zones`. Keep the
     subset that still terminates on `thebeyond` (e.g., `network`, `dmz`,
     `transit`, `external`, `ba-tunnel`, `media`).
   - Remove DHCP definitions for migrated VLANs from Kea.
   - Update IPv6: stop running DHCPv6-PD server on the migrated VLANs.
6. Verify: every existing host reaches its expected peers (DMZ ↔ APP ↔
   GUEST ↔ INFRA paths through the right gateway); operator workstation
   can SSH to `thebeyond`, `BT8-bridge`, and `BT8-gateway`.

After Phase 3: dual-gateway model is production. Manual UCI on
`BT8-gateway` and `BT8-bridge`.

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
    option ipaddr '10.97.10.<HOST_ID>'   # pick an unused host ID per registry
    option netmask '255.255.255.0'
    option gateway '10.97.10.1'           # thebeyond
    list dns '10.97.10.2'                 # phantasma (now on network)
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
config device
    option name 'bat0.50'
    option type '8021q'
    option ifname 'bat0'
    option vid '50'
# ... repeat for 10, 11, 20, 21, 30, 40, 41, 99, 100 ...
```

#### 3. Wired ports + per-VLAN bridges

```uci
# lan1, lan2, lan3 act as VLAN-tagged trunk ports for arseille / direct
# clients. Tag the appropriate VLANs per port (varies per deployment).
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
    option ip6assign '64'              # auto-assign GUA /64 from delegated prefix

# ... repeat for INFRA (11), HOME (20), LAB (21), GUEST (30),
#     IOT (40), GAME (41) ...
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
    option ipaddr '10.97.99.2'
    option netmask '255.255.255.252'  # /30
    option gateway '10.97.99.1'        # thebeyond — default route
    list dns '10.97.10.2'              # phantasma (now on network)

config interface 'transit6'
    option device 'br-v99'
    option proto 'dhcpv6'
    option reqaddress 'try'
    option reqprefix '60'              # request /60 to carve /64s
```

DMZ (100) and `network` (10) bridges exist but have no IP:

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
    option name 'br-v10'               # network (MGMT): bridges only
    option type 'bridge'
    list ports 'bat0.10'
    list ports 'lan1.10'
config interface 'mgmt'
    option device 'br-v10'
    option proto 'static'
    option ipaddr '10.97.10.<HOST_ID>'
    option netmask '255.255.255.0'
    option gateway '10.97.10.1'         # thebeyond owns network gateway
    list dns '10.97.10.2'               # phantasma (now on network)
```

#### 3a. Client AP SSIDs (per-VLAN, optional in early phases)

If the BT8-gateway is also broadcasting client SSIDs (it should — we want
the mesh to do double duty as the office wifi for clients on HOME, GUEST,
etc.), bind each SSID to the matching network. `batman-adv` over `802.11s`
ensures frames carry the right VLAN tag across the mesh.

```uci
config wifi-iface 'home_5g'
    option device 'radio1'             # same radio as mesh, or radio2 (6GHz)
    option network 'home'              # corresponds to br-v20
    option mode 'ap'
    option encryption 'sae-mixed'
    option ssid '<home-ssid>'
    option key '<home-key>'

config wifi-iface 'guest_5g'
    option device 'radio1'
    option network 'guest'
    option mode 'ap'
    option encryption 'sae-mixed'
    option ssid '<guest-ssid>'
    option key '<guest-key>'

# ... iot, game similar — bound to br-v40, br-v41 networks ...
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
    list server '10.97.10.2'         # phantasma upstream (now on network)

config dhcp 'app'
    option interface 'app'
    option start '100'
    option limit '100'
    option leasetime '12h'
    option dhcpv4 'server'
    option dhcpv6 'server'
    option ra 'server'
    list ra_flags 'managed-config' 'other-config'

# Repeat per VLAN. For untrusted VLANs, leave as-is (full DHCP).
# For management/INFRA, keep DHCP disabled — INFRA hosts use static IPs.
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

# ... mgmt, lab, untrusted ...

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

DMZ and `network` are gatewayed by `thebeyond`. BT8-gateway needs to know to
forward traffic destined for those subnets via the transit gateway.

The default route via transit (`gateway` option in the transit interface)
already covers this, since neither DMZ nor `network` are local. But a
device on HOME wanting to reach a DMZ host should route through transit;
verify with `traceroute` after bring-up.

#### 7. NTP, DNS resolver, and management

```uci
# /etc/config/system - chrony or ntpd against thebeyond
config system
    option timezone 'UTC'
    option hostname 'bt8gateway'

# ntpd
config timeserver 'ntp'
    list server '10.97.10.1'         # thebeyond NTP
```

#### 8. Verify

```sh
# Routing table
ip route
ip -6 route
# Should see: default via 10.97.99.1 dev transit; per-VLAN /24s as connected.

# IPv6 PD received?
ip -6 addr show dev transit6
# Should see a delegated address; per-VLAN bridges should auto-pick GUA /64s.

# From a host on APP, e.g.:
ping 10.97.10.1                  # thebeyond MGMT (via transit)
ping 1.1.1.1                     # internet egress through thebeyond NAT
traceroute 10.97.100.41          # langport (DMZ) - should hop through 10.97.99.1
```

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
   media-keyed devices to reach an HTPC like `oracion`) is unchanged. The
   client devices live on GUEST (BT8-gateway-owned), but the media zone
   itself is bound to the `wg-media` interface on `thebeyond`. If we later
   want internal GUEST hosts to reach an HTPC *without* a wireguard
   handshake, that's a separate forward rule on BT8-gateway and worth a
   small follow-up plan.
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

## Risks

- **Coordinated cutover (Phase 0 + Phase 3).** Both involve simultaneous
  changes on multiple devices; a misconfiguration leaves us locked out.
  Mitigation: deploy-rs `magic_rollback` for `thebeyond`; serial console
  available for BT8-gateway; explicit recovery steps in the cutover
  runbook.
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
