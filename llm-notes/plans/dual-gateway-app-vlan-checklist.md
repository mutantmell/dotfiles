# Dual-Gateway + APP VLAN — Status Checklist

Companion status doc for [`dual-gateway-app-vlan-plan.md`](dual-gateway-app-vlan-plan.md).
Each item maps to a numbered step in the plan; tick as work completes.

**Legend:** `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` skipped/N/A

---

## Phase 0a — Validation in code (no deploy)

Cannot merge until steps 4, 5, 6, and the existing test suite all pass.

- [ ] **0a.1** Pre-flight: pin OpenWrt release for BT8
  - [ ] Verify `mediatek/filogic` (MT7988A) current in pinned `defaultRelease`
  - [ ] Confirm no switch/wireless driver regressions on that release
  - [ ] `nix run .#openwrt-build -- <bt8-mesh-device> --update-pins`
- [ ] **0a.2** Pre-flight: enable PD client on `thebeyond`'s WAN
  - [ ] Add `ipv6PrefixDelegation = { enable = true; prefixLength = 60; }` to WAN block
  - [ ] Switch WAN block from `mac` to `hardwareName` matching
- [ ] **0a.3** Drop `bond0`, switch to `hardwareName`, registry refactor + phantasma move
  - [ ] (a) Switch all physical interfaces (`wan`, `lan`, `opt1`) from `mac` to `hardwareName`
  - [ ] (b) Remove `bond0` block, drop `lan` + `opt1` blocks
  - [ ] (b) Add single `lanBat` NIC block as sole `bat0` member
  - [ ] (b) Move `mtu = 1536` from removed `bond0` onto wired NIC's `network` block
  - [ ] (b) Simplify `mkVlanBridge` — drop `bond0Vlans` attribute and `v${name}.bond0` member
  - [ ] Registry refactor: introduce `gateways` table in `lib/common/data/network.nix`
  - [ ] Add `gateway` field to every existing zone
  - [ ] Refactor `rawNetworks` enrichment + `mkHost` for per-zone prefix derivation
  - [ ] Make `hostRangeCheck` prefix-length-aware
  - [ ] Add pure-eval test under `tests/lib/` for prefix-length helpers (synthetic `/30` fixture)
  - [ ] Add explicit `prefix4 = "10.97.100"` override on `dmz` zone (Phase 5 drops it)
  - [ ] Move phantasma from `management.hosts = 2` to `network.hosts = 10`
  - [ ] Rename phantasma microvm tap `vm-11-phantasma` → `vm-10-phantasma`
  - [ ] Update phantasma MAC `5E:11:AD:01:00:02` → `5E:0A:AD:01:00:0A`
  - [ ] Replace `10-vm-infra` with `10-vm-network` rule in `hosts/thebeyond/router.nix`; keep `vm-11-*` → `brINFRA`
  - [ ] Add `udp/tcp dport 53` input rules to `network` zone
  - [ ] Update phantasma's pinned IP to `10.91.10.10` (if any)
  - [ ] Drop the four pulled E8450 entries from `network.hosts` (`merkabah`, `derfflinger`, `pantagruel`, `bobcat`, `lusitania` — keep surviving one)
- [ ] **0a.4** Add/extend `tests/modules/router6-batman-wired-only.nix` VM test
  - [ ] Asserts bridges have only `bat0.<tag>` members
  - [ ] Asserts wired NIC has `mtu = 1536`
  - [ ] Asserts thebeyond zones land under `10.91.x.x` and `fdc6:55f2:0a5e:000x::/64`
  - [ ] Asserts phantasma tap matches `vm-10-*` and bridges to `brMGMT`
  - [ ] Run full suite via `./scripts/run-checks.sh`
- [ ] **0a.5** Add `tests/modules/router6-listening-sockets.nix`
  - [ ] Boot minimal router6 with kresd + kea on at least one zone
  - [ ] Assert via `ss -tlnp` / `ss -ulnp` no service binds `0.0.0.0` or `[::]`
  - [ ] Run `./scripts/run-checks.sh router6-listening-sockets`
- [ ] **0a.6** Eval-time security assertions in `modules/router6/default.nix`
  - [ ] (a) WAN zones accept wireguard only
  - [ ] (b) No DHCP server on a NAT (WAN) interface
  - [ ] (c) `icmpEcho = "disable"` on NAT zones
  - [ ] Pure-eval tests under `tests/lib/`: 1 positive + 1 negative per assertion

## Phase 0b — Hardware cutover (single maintenance window)

Phase 0b not declared done until step 13 scan passes.

- [ ] **0b.7** Stage `nixos-anywhere` from Phase 0a build (no other router config changes yet)
- [ ] **0b.8** Physically move `thebeyond` to modem closet; connect WAN
  - [ ] Relocate BT8-bridge alongside `thebeyond` if not already co-located
  - [ ] Verify mesh quality (RSSI, batman throughput counters) from new location
- [ ] **0b.9** Reconfigure current production BT8 → BT8-bridge role
  - [ ] Remove WAN interface
  - [ ] Convert to dumb AP / wireless-bridge per Runbook A
  - [ ] Disable firewall, NAT, DHCP server
  - [ ] Keep 802.11s mesh + AP radios
  - [ ] Set single management IP on `network`/VLAN 10
- [ ] **0b.10** Cutover: bring up `thebeyond`'s WAN; verify NAT, DHCP, DNS, internet
- [ ] **0b.11** Sanity-check IPv6 delegation size
  - [ ] Run `networkctl status wan` and `cat /var/lib/systemd/network/dhcp6-prefix-delegation/wan`
  - [ ] If unexpectedly larger than `/64`: file follow-up to switch to GUA-enabled posture
- [ ] **0b.12** Rename device in operator notes/labels: BT8-bridge
- [ ] **0b.13** External security scan (Runbook E) from off-network host
  - [ ] TCP scan (`-sS -p-`)
  - [ ] UDP scan (top 1000 + WG ports)
  - [ ] ICMP test (expect 100% loss)
  - [ ] Wireguard handshake sanity check
  - [ ] Internal listening-socket spot-check
  - [ ] Rendered ruleset review (`nft list ruleset`)
  - [ ] Save scan artifacts (date + deploy SHA)

## Phase 1 — Add APP and transit VLANs to registry and `thebeyond`

- [ ] **1.1** Add zones to `lib/common/data/network.nix`
  - [ ] `app` (vlanId 50, gateway `bt8gw`, hosts `{}`)
  - [ ] `netmgmt` (vlanId 12, gateway `bt8gw`, hosts `{}`)
  - [ ] `transit` (vlanId 99, prefix4 `10.255.255`, prefix6 `${ulaPrefix}:ffff`, prefixLength4 30, hosts `{thebeyond=1; bt8gw=2}`)
- [ ] **1.2** Add `mkVlanBridge` entries in `hosts/thebeyond/router.nix`
  - [ ] APP — member-only bridge, no IP on thebeyond
  - [ ] Transit — `10.255.255.1/30` and `fdc6:55f2:0a5e:ffff::1/64`
- [ ] **1.3** Add `app` and `transit` zones to `router6.zones`
  - [ ] APP: DMZ-shaped (no `accessTo`, restricted egress, selective forwards)
  - [ ] Transit: ICMP + DNS + NTP input rules; `accessTo = ["external" "ba-tunnel"]`
  - [ ] Transit `forwardRules.dmz` (lab → dmz, tharbad → dmz:9100)
  - [ ] Transit `forwardRules.iot` (trusted → iot, HA prep)
  - [ ] Transit `forwardRules.untrusted` (trusted → untrusted)
  - [ ] Confirm `network` zone `accessTo` stays empty
- [ ] **1.4** Redeploy `thebeyond` (deploy-rs with magic rollback)
  - [ ] Update downstream OpenWRT homelab L2 switch UCI: trunk APP/transit, address on `netmgmt`/12

## Phase 2 — Manual proof: BT8-bridge and BT8-gateway

- [ ] **2.1** Configure BT8-gateway by hand per Runbook B
  - [ ] APP (50) and transit (99) — L3-terminated, fw4 zones, dnsmasq + odhcpd
  - [ ] DMZ (100), GUEST (30), ADU (31), IOT (40), GAME (41), network (10) — L2-only batman passthrough (`proto 'none'`, no IP, no fw4 zone)
  - [ ] Trusted-side VLANs (INFRA/11, HOME/20, LAB/21, NETMGMT/12) — leave unconfigured for now
  - [ ] Concurrent: deploy office-side BT8 mesh APs per Runbook C
- [ ] **2.2** Introduce `router6.routes` option in `modules/router6/default.nix`
  - [ ] Add submodule type (destination, gateway, interface, metric)
  - [ ] Translate to systemd-networkd in `modules/router6/networking.nix`
  - [ ] Add `tests/lib/router6-routes.nix` evaluation test
  - [ ] Set cross-gateway routes on `thebeyond` (`10.97.0.0/16` + `fdc6:55f2:0a5e:1000::/52` via transit)
- [ ] **2.3** Verify DMZ reachability via transit
  - [ ] `traceroute 10.97.100.41` from BT8-gw-side host
  - [ ] `ip route get 10.97.100.41` on BT8-gateway shows nexthop `10.255.255.1` via `br-v99`
- [ ] **2.4** Configure DHCP for APP VLAN on BT8-gateway (dnsmasq v4 + odhcpd v6/RA); connect test device
- [ ] **2.5** Verify
  - [ ] `sysctl net.bridge.bridge-nf-call-iptables` reports `0` (or fw4 explicit accept for DMZ bridge)
  - [ ] `nft monitor trace` / `tcpdump br-v100` clean during DMZ ping across mesh
  - [ ] Test device receives DHCP from BT8-gateway
  - [ ] Test device reaches internet (NAT egress through thebeyond)
  - [ ] `dig @10.97.50.1 example.com` resolves; transit-zone DNS rule shows hits on thebeyond
  - [ ] `ss -tlnp 'sport = :53'` on thebeyond shows kresd bound to `10.255.255.1:53`
  - [ ] Test device → DMZ host: traceroute confirms APP → BT8-gw → transit → thebeyond → DMZ
- [ ] **2.6** Document any UCI snippets / kernel-tuning needed in Phase 4 implementation notes

## Phase 3 — Production cutover of office-side VLAN gateways

- [ ] **3.1** Physically install BT8-gateway in office production location
- [ ] **3.2** Add inert L3 config on BT8-gateway for INFRA (11), HOME (20), LAB (21)
  - [ ] Bridge + fw4 zone binding + odhcpd config in place, but bridge has no IP and odhcpd disabled
- [ ] **3.3** Per-VLAN cutover (scripted single SSH transaction per VLAN)
  - [ ] INFRA (11)
  - [ ] HOME (20)
  - [ ] LAB (21)
  - [ ] Confirm gratuitous ARP convergence (`arping -A`) for each
- [ ] **3.4** Apply on `thebeyond`
  - [ ] Remove IPv4 + IPv6 gateway addresses from migrated VLAN bridges (keep bridges themselves)
  - [ ] Confirm `router6.routes` cross-gateway routes still present
  - [ ] Remove `management`, `trusted`, `lab` zones from `router6.zones` + their `mkVlanBridge` entries
  - [ ] Keep `app` zone as no-op-by-design (member-only `brVAPP`, no IP/DHCP/rules)
  - [ ] Confirm `network`, `dmz`, `transit`, `external`, `ba-tunnel`, `media`, untrusted family kept
  - [ ] Remove DHCP definitions for migrated VLANs from Kea
  - [ ] Stop DHCPv6-PD server on migrated VLANs
- [ ] **3.5** Verify connectivity (DMZ ↔ APP ↔ GUEST ↔ INFRA paths; SSH to thebeyond, BT8-bridge, BT8-gateway)
- [ ] **3.6** Re-run external scan runbook (Runbook E) — internal listening-socket and rendered ruleset review especially

## Phase 4 — Codify BT8-gateway and BT8-bridge in Image Builder

- [ ] **4.1** Extend `lib/common/data/openwrt.nix`
  - [ ] Add BT8 target/subtarget; pin Image Builder hash via `--update-pins`
  - [ ] Audit `meshVlans` table — every batman-trunked VLAN is now a mesh VLAN
- [ ] **4.2** Define new `type` values
  - [ ] `wirelessBridge` (flat L2 bridge across wired uplink + batman-adv mesh)
  - [ ] `gateway` (per-VLAN bridges, fw4 zones, odhcpd, batman participation, optional client APs)
- [ ] **4.3** Extend existing `meshAP` type to accept BT8 hardware (target + packages)
- [ ] **4.4** Generate fw4 UCI from structured zone description in Nix
- [ ] **4.5** Generate odhcpd UCI per VLAN from registry data
- [ ] **4.6** Add pure-Nix evaluation snapshot tests under `tests/openwrt/`
- [ ] **4.7** Cutover devices to image-builder one at a time
  - [ ] BT8-bridge — capture manual UCI as backup, build, deploy
  - [ ] BT8-gateway — capture manual UCI as backup, build, deploy

## Phase 4.5 — Lock down BT8-gateway/BT8-bridge management plane

- [ ] **4.5.1** Decide management-host allowlist (operator workstation IPs on `network`/`management`, future pusher host) and document in OpenWrt zone description
- [ ] **4.5.2** Add `inputRules` restriction: drop SSH (22) + LuCI (80/443) from sources outside allowlist
- [ ] **4.5.3** Build new image with lockdown
  - [ ] Dry-run via runtime UCI on BT8-gateway (`fw4 reload`)
  - [ ] Confirm operator can still SSH; revert runtime change
- [ ] **4.5.4** Deploy image-built lockdown to BT8-gateway first; verify; then BT8-bridge
- [ ] **4.5.5** Capture pre-lockdown UCI as rollback artifact

## Phase 5 — Move services into APP

Per-host moves (each move = re-IP, DNS, hardening profile, cross-gateway rules, retest):

- [ ] **5.A** `oracion` (Jellyfin) → APP
  - [ ] Re-IP into `10.97.50.x`; update registry
  - [ ] Update DNS (auto-regenerated)
  - [ ] Apply DMZ host-hardening profile (host firewall + `mkEgressFilter`)
  - [ ] **Required:** add `transit → app` rule on BT8-gateway sourced `10.100.20.0/24` (wg-media) → oracion on Jellyfin/Navidrome/Retrom ports
  - [ ] Retest: in-zone, cross-zone via BT8-gateway, internet, all wg-media paths
- [ ] **5.B** `creil` (Forgejo internal) → APP
  - [ ] Re-IP, DNS, hardening, retest
  - [ ] Translate any wg-* sources from existing inbound DMZ forward rules
- [ ] **5.C** `zeiss` (Attic) → APP
  - [ ] Re-IP, DNS, hardening, retest
  - [ ] Translate any wg-* sources
- [ ] **5.D** `saint-arkh` (CI runners) → APP
  - [ ] Re-IP, DNS, hardening, retest
  - [ ] If saint-arkh → DMZ flows needed: add transit→dmz rule scoped to saint-arkh source IP

After all moves complete:

- [ ] **5.E** Drop `prefix4 = "10.97.100"` override on `dmz` zone in `lib/common/data/network.nix`
- [ ] **5.F** Re-IP `langport` to `10.91.100.41` (dual-stack window pattern)
- [ ] **5.G** Re-IP `trista` to `10.91.100.51` (dual-stack window pattern)
- [ ] **5.H** Update `thebeyond`'s `dmz` bridge to `10.91.100.1/24`
- [ ] **5.I** Check `basel`'s step-ca issuance templates; re-issue any cert pinning `10.97.100.<id>`
- [ ] **5.J** Confirm Cloudflare DNS for `langport`'s WAN side unaffected

---

## Outstanding open items / dependencies

- [ ] Last E8450 mesh AP decommission (tracked separately, optional)
- [ ] OpenWRT homelab L2 switch into the flake (follow-up plan; gives `netmgmt.hosts` entry)
- [ ] `arseille` deferred to follow-up plan (stays in `network.hosts` until reclassified)
- [ ] Pusher host zone placement (out of scope; revisits Phase 4.5 allowlist)
- [ ] HA host on IoT VLAN — tighten transit `forwardRules.iot` to HA host IP + 8123 once registered
