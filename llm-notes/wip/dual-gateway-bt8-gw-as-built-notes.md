# BT8-gateway as-built notes (Phase 2.6)

Source of truth: `temp/BT8-gw-current.uci` (UCI dump from the running
BT8-gateway after Phase 2.1 cutover).

This file captures (a) deltas from `llm-notes/guides/bt8-gateway-luci-runbook.md`,
(b) implementation choices that worked in production and should be the
default for Phase 4 image-builder codification, and (c) loose ends that
need follow-up.

## Deltas from Runbook B

### Mesh radio on 6 GHz (radio2), not 5 GHz

Runbook 5.A presumed the 5 GHz radio (radio1) for the mesh. As-built uses
radio2 (6 GHz, EHT160, channel 57, country GB). Reasons (verify with
operator before Phase 4): MT7988A 6 GHz radio is unloaded, gives mesh
its own band without competing with client APs on 2.4/5 GHz, and EHT160
provides headroom for batman-adv overhead.

Mesh wifi-iface device path is `phy0.2-mesh0` (radio index 2), matching.

**Phase 4 implication:** image-builder `meshAP` / `gateway` types should
default mesh to radio2, not radio1. Document the rationale in
`lib/openwrt/types/<role>.nix`.

### Trunk port architecture: `br0` + `bridge-vlan` filtering, not per-VLAN `<TRUNK>.<vid>` netdevs

Runbook 5.F builds `<TRUNK>.<vid>` 8021q sub-devices on the wired trunk
port directly. As-built uses a cleaner OpenWrt-native pattern:

- A `br0` bridge over the trunk port(s) (`lan2`, `lan3`).
- Per-VLAN `bridge-vlan` filtering blocks under `br0` (e.g. `vlan '255'`
  on `lan2:t`).
- Per-VLAN `br-v<vid>` L2-passthrough bridges with both `bat0.<vid>`
  (mesh side) and `br0.<vid>` (the auto-created bridge-VLAN device on
  the wired side) as members.

Advantages:

- Single trunk port can be tagged/untagged per-VLAN cleanly.
- `lan3` is configured as an untagged access port for HOME/20 (operator
  workstation) without needing a separate `lan3` device block.
- Mirrors OpenWrt 22.03+ DSA-style switch config; future-proof.

**Phase 4 implication:** generate `br0` + `bridge-vlan` per trunk port,
not per-VLAN 8021q sub-devices. The `gateway` type in `lib/openwrt/`
should emit this pattern.

### VLANs 11 / 20 / 21 trunked early (deviation from Phase 2 scope)

Runbook Phase 2 leaves INFRA/11, HOME/20, LAB/21 unconfigured and defers
them to Phase 3. In practice the wired homelab L2 switch sits **behind**
BT8-gateway (lan2 trunk), so frames on those VLANs must traverse
BT8-gateway as wired-side tags _before_ Phase 3, otherwise the homelab
loses connectivity through the gateway.

As-built adds:

- `bridge-vlan` filter entries for `vlan '11'`, `vlan '20'`, `vlan '21'`
  on `lan2:t` (and `lan3` untagged for `vlan '20'`, the operator HOME
  access port).
- `bat0.11`, `bat0.20`, `bat0.21` 8021q sub-devices.
- `br-v11`, `br-v20`, `br-v21` L2-passthrough bridges (`bat0.<vid>` +
  `br0.<vid>`).
- `config interface 'mgmt' / 'home' / 'lab'` with `proto 'none'` — no IP,
  no fw4 zone, no odhcpd. Still L3-terminated on thebeyond.

This is the same shape as DMZ/GUEST/ADU/IOT/GAME — L2 passthrough only.

**Plan implication:** the Phase 2.1 checklist boxed "leave INFRA/11,
HOME/20, LAB/21 unconfigured" is too strict. They need to exist as
L2-passthrough during Phase 2; Phase 3 promotes them to L3-terminated
by adding the bridge IP and odhcpd config. Updated the checklist with a
`[~]` and explanation.

### iot / game `config interface` references the bare `bat0.<vid>` instead of `br-v<vid>`

UCI lines:

```
config interface 'iot'
        option proto 'none'
        option device 'bat0.40'

config interface 'game'
        option proto 'none'
        option device 'bat0.41'
```

But `br-v40` and `br-v41` bridges exist with both `bat0.4x` and
`br0.4x` as members. Functionally fine — `proto 'none'` means no L3
config, and L2 frames bridge via the `br-v<vid>` bridge regardless of
what the `config interface` block points at. Inconsistent with DMZ /
GUEST / ADU which correctly point at `br-v<vid>`.

**Phase 4 implication:** normalize. All L2-passthrough interfaces
should `option device 'br-v<vid>'`. Pure cosmetic / Nix-consistency win;
no behavior change.

### ULA prefix mismatch in `network.globals.ula_prefix`

```
option ula_prefix 'fd7d:f3b0:a41a::/48'
```

This is OpenWrt's auto-generated default. Project ULA is
`fdc6:55f2:0a5e::/48`. The mismatch is benign — actual interface
addresses are hardcoded via `list ip6addr 'fdc6:55f2:0a5e:...'` and the
globals value is only used when `ip6assign` auto-derives, which we
don't rely on. Worth aligning in Phase 4 for consistency.

## Implementation choices worth preserving (Phase 4 defaults)

- `dnsmasq.ednspacket_max '1232'` — modern EDNS payload size, avoids
  fragmentation issues. Keep as default.
- `dnsmasq.cachesize '1000'` — sensible default for a small fleet.
  Configurable in the gateway type.
- `dnsmasq.local '/internal/'` + `option domain 'internal'` —
  consistent with thebeyond's `dns.localDomain = "internal"`.
- `dnsmasq.noresolv '1'` + single `server '10.255.255.1'` — forces all
  recursion through the transit nexthop (thebeyond's kresd). Removes
  the chance of dnsmasq sneaking out to an ISP resolver.
- odhcpd RA flags `managed-config` + `other-config` (M=1, O=1) on APP —
  stateful DHCPv6 + DNS via RA. Matches the registry's `dhcp6.mode =
"stateful"` posture (verify which mode we actually want; SLAAC would
  be flagless).
- `option ip6gw 'fdc6:55f2:0a5e:ffff::1'` on the transit interface —
  explicit v6 gateway. Required because transit is a static /64
  point-to-point with no RA; without it BT8-gateway has no default v6
  route via transit.
- batman-adv `hop_penalty '30'` on `bat0`. Worth documenting / setting
  as the gateway type default. Higher penalty = batman prefers fewer
  hops; relevant when multiple BT8-mesh APs add hop options.
- **`ra_default '1'` on every L3-terminated VLAN's dhcp block.**
  **Required for ULA-only setups.** odhcpd's default heuristic
  suppresses the default-router advertisement in RAs when no GUA
  prefix is delegated. ULA-only deployments fail the check — clients
  get a SLAAC address but no IPv6 default route. As-built `dhcp.app`
  is missing this (latent bug; no APP clients to expose it yet).
  Phase 4's gateway type should emit `ra_default '1'` for every
  L3-terminated VLAN by default.
- `mesh_fwding '0'` on the wifi-iface mesh node — disables native 802.11s
  forwarding so batman-adv handles forwarding (avoids double-forwarding
  loops). **Required**.

## Loose ends / follow-ups

- **NETMGMT/12 not yet trunked.** Add when the OpenWRT homelab L2 switch
  folds into the flake (separate plan). At that point: `bridge-vlan`
  filter on `lan2:t`, `bat0.12`, `br-v12`. Still L2-only on BT8-gateway
  unless we decide BT8-gateway should hold `10.97.12.1` natively.
- **No production SSIDs on radio0/radio1.** All client WiFi is
  broadcast by BT8-bridge (modem closet, wired to thebeyond) and bound
  to GUEST/30 (untrusted, terminated on thebeyond). HOME/INFRA/LAB are
  wired-only by design — no wireless coverage to preserve through
  Phase 3 cutover. BT8-gateway's radio0/radio1 stay disabled.
  Runbook C's office-side mesh APs are only relevant for extending
  mesh fabric range; not needed if BT8-bridge ↔ BT8-gateway see each
  other on 6 GHz directly.
- **`lan` zone is wide-open** (`input ACCEPT`, `forward ACCEPT`, no
  source filter). This is the management surface (br-lan / lan1 /
  192.168.1.1). Phase 4.5 (management plane lockdown) restricts
  SSH/LuCI on this zone to the operator allowlist.
- **No `transit → app` reverse forwarding.** Today only `app → transit`
  and `lan → transit` are configured. If a future flow needs thebeyond
  to initiate inbound to an APP-resident host (e.g. monitoring scrape
  of an APP service), add a `transit → app` forwarding with appropriate
  rules.

## Anchor for Phase 4

Phase 4.1 builds the BT8 image-builder target and pins hashes. The
gateway type (Phase 4.2) should produce a UCI substantially identical
to `temp/BT8-gw-current.uci` — taking that file as the "golden output"
for the gateway snapshot test is the cleanest way to gate Phase 4.7's
cutover (build the image, render UCI, diff against the snapshot, fix
any drift before flashing).
