# BT8-gateway as-built reference

Snapshot of BT8-gateway's deployed state, kept here as the operator
reference until Phase 4 codifies the same shape into the image-builder
pipeline (see [`plans/dual-gateway-followups-plan.md`](plans/dual-gateway-followups-plan.md)
§B.1). Updated in place whenever live UCI diverges from what's recorded.

Source dumps live in `temp/`:

- `temp/BT8-gw-current.uci` — full UCI dump from the running BT8-gateway
  after Phase 2.1 cutover (2026-05-29). Not re-captured per change.
- `temp/BT8-gw-phase-5a-additions.uci` — fw4 additions applied 2026-05-31
  during oracion's DMZ→APP move.
- `temp/BT8-gw-section-a-additions.uci` — fw4 additions for the remaining
  Phase 5 service migrations (creil, zeiss, saint-arkh DMZ→APP). Apply
  after the Nix-side re-IPs deploy. Companion to
  [`plans/dual-gateway-followups-plan.md`](plans/dual-gateway-followups-plan.md)
  Section A.
- `temp/BT8-gw-cluster-vlan51-additions.uci` — L2/L3 + fw4 additions for the
  cluster VLAN 51 bring-up (dev-machine isolation). Companion to
  [`plans/cluster-vlan-bringup-checklist.md`](plans/cluster-vlan-bringup-checklist.md)
  Phases B.1 + C. **Staged**; L3 termination reported live 2026-06-09 (see the
  Cluster VLAN 51 section below).

This file captures (a) deltas from
[`guides/bt8-gateway-luci-runbook.md`](guides/bt8-gateway-luci-runbook.md),
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

## Phase 5.A additions (2026-05-31) — oracion moved DMZ → APP

UCI source: `temp/BT8-gw-phase-5a-additions.uci`. Added on BT8-gateway
when `oracion` (Jellyfin / Navidrome / Retrom) migrated from `10.97.100.52`
(DMZ on thebeyond) to `10.97.50.52` (APP on BT8-gateway).

Two new zone-pair forwarding directives + three per-flow accept rules:

| Direction          | Flow                                  | Ports                                |
| ------------------ | ------------------------------------- | ------------------------------------ |
| `transit → app`    | wg-media (`10.100.20.0/24`) → oracion | tcp 443                              |
| `app → management` | oracion → basel                       | tcp 443 (ACME)                       |
| `app → management` | oracion → tharbad                     | tcp 3100, 8427 (Loki + metrics push) |

**fw4 gotcha:** per-rule accepts alone weren't sufficient — fw4 only
evaluates inter-zone rules when a matching `config forwarding`
directive opens the zone pair. Without it the zone's `forward 'REJECT'`
policy fires first and rules never get reached (symptom: ICMP
"destination port unreachable" from the gateway IP, even though
`uci show firewall` shows the rule loaded). Both directives are
therefore broad accepts; the per-rule entries document intent but don't
tighten the zone-pair policy further. Tightening would need custom
chain rules; deferred unless an actual leak is found.

This resolves the previous loose-end "No transit → app reverse
forwarding."

## Section A additions — creil / zeiss / saint-arkh moved DMZ → APP

UCI source: `temp/BT8-gw-section-a-additions.uci`. Companion to
[`plans/dual-gateway-followups-plan.md`](plans/dual-gateway-followups-plan.md)
Section A.

Three new zone-pair forwarding directives + per-flow accept rules:

| Direction          | Flows                                     | Ports                                |
| ------------------ | ----------------------------------------- | ------------------------------------ |
| `app → management` | creil/zeiss/saint-arkh → basel            | tcp 443 (ACME)                       |
| `app → management` | creil/zeiss/saint-arkh → tharbad          | tcp 3100, 8427 (Loki + metrics push) |
| `app → management` | saint-arkh → roer                         | tcp 443 (deployd API)                |
| `management → app` | management VLAN → creil                   | tcp 22, 443 (Forgejo)                |
| `management → app` | management VLAN → zeiss                   | tcp 443 (Attic cache)                |
| `trusted → app`    | HOME (operator workstation) → app (broad) | (zone-pair accept; per-rule TBD)     |
| `lab → app`        | edith → app (broad)                       | (zone-pair accept; per-rule TBD)     |

No `transit → app` per-flow rules needed for this batch — no wg-\* flows
currently target creil/zeiss/saint-arkh. `app → app` intra-zone flows
(e.g. saint-arkh → zeiss Attic push) traverse the APP bridge directly
without involving fw4.

## Phase 2d addition — oracion → messeldam LDAP

UCI source: `temp/BT8-gw-phase-2d-additions.uci`. Companion to the Authelia
migration (`wip/authelia-migration-plan.md` Phase 2d). Added when oracion's
Jellyfin LDAP plugin started authenticating media users against lldap on
messeldam.

One per-flow accept rule — the `app → management` forwarding directive already
exists (Phase 5.A), so no new `config forwarding` was needed:

| Direction          | Flow                | Ports                          |
| ------------------ | ------------------- | ------------------------------ |
| `app → management` | oracion → messeldam | tcp 3890 (lldap LDAP, v4 only) |

IPv4-only: lldap on messeldam binds `0.0.0.0` (IPv4) and its host firewall
admits only oracion's IPv4, so there's no v6 path to open. Add a v6 dest_ip
plus a matching messeldam-side input rule only if lldap is later dual-stacked.

## Cluster VLAN 51 additions (2026-06-09) — dev-machine isolation

UCI source: `temp/BT8-gw-cluster-vlan51-additions.uci`. Companion to
[`plans/cluster-vlan-bringup-checklist.md`](plans/cluster-vlan-bringup-checklist.md)
Phases B.1 (L2) + C (fw4). Stands up the low-trust `cluster` zone
(`10.97.51.0/24` + `fdc6:55f2:0a5e:1033::/64`) where the locked-down KubeVirt
dev-machine lives, router-confined off erebonia's VLAN-11 management plane. The
erebonia flake half (`uplink.51` + host-IP-less `br51`) landed separately; this
is the bt8gw-manual half.

**Status (2026-06-09):** L3 termination **live** — `ping 10.97.51.1` answers
(§1 L2 trunk + L3 interface, B.1/C.1). The fw4 zone + egress allowlist (§2,
C.2–C.6) is **operator-confirmed enforcing** — VLAN 51 reaches only transit
(WAN), zeiss, and creil; the rest of app (oracion, saint-arkh, …) and all other
internal zones are denied. **The broad-accept risk below did NOT materialize**
— cluster→app is tight, not broad.

DNS is **also confirmed**: a `Allow-DNS-DHCP-cluster` rule admits VLAN 51 to the
bt8gw resolver (dnsmasq input :53), so the multus-only dev VM can resolve
`dev-N.internal`. (That live rule name differs from the staged §2
`Allow-cluster-DNS` — reconcile when capturing the as-built delta.)

**One residual, not yet captured here verbatim:** which mechanism enforces the
app allowlist (plain §2 vs the §2b nft include) was not recorded. Capture it
(and the exact UCI delta) on the next device touch — `uci show firewall` +
`nft list ruleset` — and update the table below.

L3 termination (same shape as APP/50 — see "Trunk port architecture"):

| Layer  | Object              | Detail                                            |
| ------ | ------------------- | ------------------------------------------------- |
| wired  | `br0` bridge-vlan   | tag 51 on `lan2:t`                                |
| mesh   | `bat0.51`           | 8021q sub-device                                  |
| bridge | `br-v51`            | members `bat0.51` + `br0.51`                      |
| L3     | interface `cluster` | `10.97.51.1/24` + `…1033::1/64`, no default route |

fw4 cluster zone — default-deny, egress allowlist only:

| Direction                 | Flow                                   | Ports                                  |
| ------------------------- | -------------------------------------- | -------------------------------------- |
| `cluster → Device(input)` | dev VM → bt8gw dnsmasq (resolver)      | udp/tcp 53                             |
| `cluster → app`           | dev VM → creil (git)                   | tcp 22, 443                            |
| `cluster → app`           | dev VM → zeiss (Attic)                 | tcp 443                                |
| `cluster → transit`       | dev VM → WAN via thebeyond NAT         | (broad; thebeyond gates onward)        |
| `cluster → *`             | management / lab / trusted / app-other | **deny** (zone forward REJECT default) |
| `lab → cluster` (ingress) | lab (incl. edith) → cluster            | **already broadly permitted** (existing bt8gw forwarding) |
| `wg-vpn → cluster` (ingress) | wg-vpn peers → cluster              | **already broadly permitted** (existing bt8gw forwarding) |

**Operator ingress (D.6) — `lab → cluster` SSH already works.** The multus-only
dev VM has no pod network, so the old `kubectl port-forward`→masquerade SSH path
is gone; the `dev-machine` launcher on edith now SSHes straight to
`dev-N.internal`. bt8gw **already** forwards the lab VLAN and the wg-vpn IP block
to the cluster VLAN broadly (operator-confirmed 2026-06-09), so that direct-SSH
path — and the Phase-E mobile path — are reachable today with **no new fw4 rule**.
A scoped `lab → cluster` accept (src edith `10.97.21.42`, dst the dev band
`.10-.25`, tcp 22) is staged in temp/BT8-gw-cluster-vlan51-additions.uci §2c only
as an **optional tightening** if the broad lab→cluster forwarding is ever narrowed
— it is **not** required for the cutover. (Tightening would hit the same fw4 gotcha
as `cluster → app`; scoping by `dest_ip`/`dest_port` is acceptable because cluster
holds only dev slots.)

**fw4 gotcha — the one real risk here (same root as Phase 5.A).** The Phase-5.A
note records that per-rule inter-zone ACCEPTs don't fire on this fw4 version
unless a `config forwarding` opens the zone pair — but that forwarding is a
**broad** accept the per-rule entries can't tighten. For `transit → app` that
was acceptable (broad was wanted). For **`cluster → app` it is not**: a broad
accept hands the untrusted dev VM all of app (oracion, saint-arkh, …), which is
exactly the blast radius the dedicated `cluster` zone exists to avoid
(workload-network-isolation-plan.md "Why a dedicated zone, not app"). The staged
UCI therefore ships the plain per-rule form **plus a `§2b` nft config-include
fallback** that enforces the three-flow allowlist with an explicit drop. **Which
one actually restricts must be verified on the device** (`nc` to oracion
`10.97.50.52:443` from VLAN 51 MUST time out); run-checks.sh cannot catch this.
Record which mechanism ended up enforcing once verified.

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
- **`app → management` and `transit → app` are broad zone-pair
  accepts.** Phase 5.A added these because fw4 won't fire per-rule
  accepts without them, but the per-rule entries we wrote can't
  tighten the zone-pair policy itself on this version. If Phase 5
  expands (creil, zeiss, saint-arkh into APP) and the per-flow list
  grows, revisit whether custom chains or per-rule defaults can give
  back strict-by-default at the zone-pair level.

## Anchor for Phase 4

Phase 4.1 builds the BT8 image-builder target and pins hashes. The
gateway type (Phase 4.2) should produce a UCI substantially identical
to `temp/BT8-gw-current.uci` — taking that file as the "golden output"
for the gateway snapshot test is the cleanest way to gate Phase 4.7's
cutover (build the image, render UCI, diff against the snapshot, fix
any drift before flashing).
