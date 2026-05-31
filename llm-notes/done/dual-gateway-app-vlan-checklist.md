# Dual-Gateway + APP VLAN — Status Checklist

**Status: COMPLETE** as of 2026-05-31. Phases 0a / 0b / 1 / 2 / 3 / 5.A
shipped. Items below 5.A (5.B onward, Phase 4 / 4.5, outstanding open
items) moved to [`../plans/dual-gateway-followups-plan.md`](../plans/dual-gateway-followups-plan.md)
and are intentionally left unchecked here as historical record.

Companion status doc for [`dual-gateway-app-vlan-plan.md`](dual-gateway-app-vlan-plan.md).
Each item maps to a numbered step in the plan; tick as work completes.

**Legend:** `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` skipped/N/A

---

## Phase 0a — Validation in code (no deploy)

Cannot merge until steps 4, 5, 6, and the existing test suite all pass.

- [~] **0a.1** Pre-flight: pin OpenWrt release for BT8
  - [x] Release selected: **25.12** (BT8 already flashed with stock 25.12; Firmware Selector image will pin same)
  - [ ] Use ≥ **25.12.3** for Firmware Selector build — 25.12.1 introduced a MediaTek 2.4 GHz latency regression hot-fixed in 25.12.2; 25.12.3 adds further `mediatek/filogic` fixes
  - [ ] Watch batman-adv throughput during `0b.8` mesh-quality check — MT7981/MT7986 had a slow-TX bug on batman-adv mesh in 24.10.x (`openwrt/openwrt#18703`); MT7988A is same Filogic family, behavior on 25.12 unverified
  - [ ] Flake pin advance deferred to **Phase 4.1** — `openwrt-hashes.json` only carries hashes for targets that have a device in `openwrt.nix`, and BT8 lands there in 4.1. At that point: bump `defaultRelease` → 25.12 and `nix run .#openwrt-build -- <bt8-device> --update-pins`
- [x] **0a.2** Pre-flight: enable PD client on `thebeyond`'s WAN
  - [x] Add `ipv6PrefixDelegation = { enable = true; prefixLength = 60; }` to WAN block
  - [-] Switch WAN block from `mac` to `hardwareName` matching (skipped — `hardwareName` rename is broken, see Outstanding open items; topology uses kernel name `enp4s0` directly)
- [x] **0a.3** Drop `bond0`, switch to `hardwareName`, registry refactor + phantasma move
  - [x] (a) Switch all physical interfaces (`wan`, `lan`, `opt1`) from `mac` to `hardwareName`
  - [x] (b) Remove `bond0` block, drop `lan` + `opt1` blocks
  - [x] (b) Add single `lanBat` NIC block as sole `bat0` member
  - [x] (b) Move `mtu = 1536` from removed `bond0` onto wired NIC's `network` block
  - [x] (b) Simplify `mkVlanBridge` — drop `bond0Vlans` attribute and `v${name}.bond0` member
  - [x] Registry refactor: introduce `gateways` table in `lib/common/data/network.nix`
  - [x] Add `gateway` field to every existing zone
  - [x] Refactor `rawNetworks` enrichment + `mkHost` for per-zone prefix derivation
  - [x] Make `hostRangeCheck` prefix-length-aware
  - [x] Add pure-eval test under `tests/lib/` for prefix-length helpers (synthetic `/30` fixture)
  - [x] Add explicit `prefix4 = "10.97.100"` override on `dmz` zone (Phase 5 drops it)
  - [x] Move phantasma from `management.hosts = 2` to `network.hosts = 10`
  - [x] Rename phantasma microvm tap `vm-11-phantasma` → `vm-10-phantasma`
  - [x] Update phantasma MAC `5E:11:AD:01:00:02` → `5E:0A:AD:01:00:0A`
  - [x] Replace `10-vm-infra` with `10-vm-network` rule in `hosts/thebeyond/router.nix`; keep `vm-11-*` → `brINFRA`
  - [x] Add `udp/tcp dport 53` input rules to `network` zone
  - [x] Update phantasma's pinned IP to `10.91.10.10` (if any)
  - [x] Drop the four pulled E8450 entries from `network.hosts` (`merkabah`, `derfflinger`, `pantagruel`, `bobcat`, `lusitania` — keep surviving one)
- [x] **0a.4** Add/extend `tests/modules/router6-batman-wired-only.nix` VM test
  - [x] Asserts bridges have only `bat0.<tag>` members
  - [x] Asserts wired NIC has `mtu = 1536`
  - [x] Asserts addresses generated correctly (`fdc6:55f2:0a5e:a::1` for subnetId=10 → "000a")
  - [x] Run full suite via `./scripts/run-checks.sh`
- [x] **0a.5** Add `tests/modules/router6-listening-sockets.nix`
  - [x] Boot minimal router6 with kresd + kea on at least one zone
  - [x] Assert via `ss -tlnp` / `ss -ulnp` no service binds `0.0.0.0` or `[::]`
  - [x] Run `./scripts/run-checks.sh router6-listening-sockets`
- [x] **0a.6** Eval-time security assertions in `modules/router6/default.nix`
  - [x] (a) WAN zones accept wireguard only
  - [x] (b) No DHCP server on a NAT (WAN) interface
  - [x] (c) `icmpEcho = "disable"` on NAT zones
  - [x] Pure-eval tests under `tests/lib/`: 1 positive + 1 negative per assertion

## Phase 0b — Hardware cutover (single maintenance window)

Phase 0b not declared done until step 13 scan passes.

- [x] **0b.7** Stage `nixos-anywhere` from Phase 0a build (no other router config changes yet)
- [x] **0b.8** Physically move `thebeyond` to modem closet; connect WAN
  - [x] Relocate BT8-bridge alongside `thebeyond` if not already co-located
  - [x] Verify mesh quality (RSSI, batman throughput counters) from new location
  - [x] `iperf3` BT8-bridge ↔ BT8-mesh-AP, both directions, record number — canary for `openwrt/openwrt#18703` (slow-TX batman-adv on Filogic). Under ~100 Mbps on 5 GHz mesh = hold cutover.
  - [x] Carry a 24.10.5 BT8 sysupgrade image (built via Firmware Selector with same F.1 recipe) in operator secret store as in-window fallback if 25.12 batman performance is broken.
- [x] **0b.9** Reconfigure current production BT8 → BT8-bridge role
  - [x] Remove WAN interface
  - [x] Convert to dumb AP / wireless-bridge per Runbook A
  - [x] Disable firewall, NAT, DHCP server
  - [x] Keep 802.11s mesh + AP radios
  - [x] Set single management IP on `network`/VLAN 10
- [x] **0b.10** Cutover: bring up `thebeyond`'s WAN; verify NAT, DHCP, DNS, internet
- [x] **0b.11** Sanity-check IPv6 delegation size
  - [x] Run `networkctl status wan` and `cat /var/lib/systemd/network/dhcp6-prefix-delegation/wan`
  - [-] If unexpectedly larger than `/64`: file follow-up to switch to GUA-enabled posture (ISP delegated `/64` as expected — noted in WAN block comment)
- [x] **0b.12** Rename device in operator notes/labels: BT8-bridge
- [x] **0b.13** External security scan (Runbook E) from off-network host
  - [x] TCP scan (`-sS -p-`)
  - [x] UDP scan (top 1000 + WG ports)
  - [x] ICMP test (expect 100% loss)
  - [x] Wireguard handshake sanity check
  - [x] Internal listening-socket spot-check
  - [x] Rendered ruleset review (`nft list ruleset`)
  - [x] Save scan artifacts (date + deploy SHA)

## Phase 1 — Add APP and transit VLANs to registry and `thebeyond`

- [x] **1.1** Add zones to `lib/common/data/network.nix`
  - [x] `app` (vlanId 50, gateway `bt8gw`, hosts `{}`)
  - [x] `netmgmt` (vlanId 12, gateway `bt8gw`, hosts `{}`)
  - [x] `transit` (vlanId 255, prefix4 `10.255.255`, prefix6 `${ulaPrefix}:ffff`, prefixLength4 30, hosts `{thebeyond=1; bt8gw=2}`)
- [x] **1.2** Add `mkVlanBridge` entries in `hosts/thebeyond/router.nix`
  - [x] APP — member-only bridge, no IP on thebeyond (`mkMemberOnlyBridge`)
  - [x] Transit — `10.255.255.1/30` and `fdc6:55f2:0a5e:ffff::1/64` (`transitBridge`)
- [x] **1.3** Add `app` and `transit` zones to `router6.zones`
  - [x] APP: empty placeholder (no `accessTo`, no input/forward rules) — selective forwards/egress will be added in Phase 5 when services migrate
  - [x] Transit: ICMP + DNS + NTP input rules; `accessTo = ["external" "ba-tunnel"]`
  - [x] Transit `forwardRules.dmz` (lab → dmz, tharbad → dmz:9100)
  - [-] Transit `forwardRules.iot` (trusted → iot, HA prep) — deliberately omitted; iot/adu/game all bind into the `untrusted` zone via subnetBindings, so the broad `forwardRules.untrusted` already covers HA access. Split iot into its own router6 zone first if a tighter rule is wanted (note in `hosts/thebeyond/router.nix:545-549`).
  - [x] Transit `forwardRules.untrusted` (trusted → untrusted)
  - [x] Confirm `network` zone `accessTo` stays empty
- [x] **1.4** Redeploy `thebeyond` (deploy-rs with magic rollback) — landed via commit `2767a25` + follow-up deploys
  - [x] Update downstream OpenWRT homelab L2 switch UCI: trunk APP/transit, address on `netmgmt`/12 — operator handled out-of-flake; folded back in via follow-up plan

## Phase 2 — Manual proof: BT8-bridge and BT8-gateway

- [x] **2.0** PREREQUISITE GATE — verify transit reachability before opening the BT8-gateway window
  - [x] thebeyond's `transit` bridge (`brTRANSIT`, `10.255.255.1/30`, `fdc6:55f2:0a5e:ffff::1/64`) deployed and up (Phase 1.4 complete)
  - [x] BT8-bridge wired uplink to thebeyond trunks VLAN 255 as a tagged member (mesh-side `bat0.255` reaches BT8-bridge transparently via batman; wired uplink needs explicit VLAN-tag passthrough config)
  - [x] From any host on `network`/10: `ping 10.255.255.1` succeeds, both directions
- [x] **2.1** Configure BT8-gateway by hand per Runbook B
  - [x] APP (50) and transit (255) — L3-terminated, fw4 zones, dnsmasq + odhcpd
  - [x] DMZ (100), GUEST (30), ADU (31), IOT (40), GAME (41), network (10) — L2-only batman passthrough (`proto 'none'`, no IP, no fw4 zone)
  - [~] Trusted-side VLANs (INFRA/11, HOME/20, LAB/21, NETMGMT/12) — **deviation from plan:** VLANs 11/20/21 were added to BT8-gateway's wired trunk bridge (`br0` with `bridge-vlan` filtering) and given L2-passthrough `br-v<vid>` bridges so the downstream homelab gear could reach thebeyond through BT8-gateway. They are still L2-only on BT8-gateway (no IP, no fw4 zone, no odhcpd) — L3 termination still lives on thebeyond and moves in Phase 3. NETMGMT/12 not yet trunked.
  - [ ] Concurrent: deploy office-side BT8 mesh APs per Runbook C
- [x] **2.2** Introduce `router6.routes` option in `modules/router6/default.nix`
  - [x] Add submodule type (destination, gateway, interface, metric)
  - [x] Translate to systemd-networkd in `modules/router6/networking.nix`
  - [x] Add `tests/lib/router6-routes.nix` evaluation test
  - [x] Set cross-gateway routes on `thebeyond` (`10.97.0.0/16` + `fdc6:55f2:0a5e:1000::/52` via transit)
- [x] **2.3** Verify DMZ reachability via transit
  - [x] `traceroute 10.97.100.41` from BT8-gw-side host
  - [x] `ip route get 10.97.100.41` on BT8-gateway shows nexthop `10.255.255.1` via `br-v255`
- [x] **2.4** Configure DHCP for APP VLAN on BT8-gateway (dnsmasq v4 + odhcpd v6/RA); connect test device
- [x] **2.5** Verify
  - [x] `sysctl net.bridge.bridge-nf-call-iptables` reports `0` (or fw4 explicit accept for DMZ bridge)
  - [x] `nft monitor trace` / `tcpdump br-v100` clean during DMZ ping across mesh
  - [x] Test device receives DHCP from BT8-gateway
  - [x] Test device reaches internet (NAT egress through thebeyond)
  - [x] `dig @10.97.50.1 example.com` resolves; transit-zone DNS rule shows hits on thebeyond
  - [x] `ss -tlnp 'sport = :53'` on thebeyond shows kresd bound to `10.255.255.1:53`
  - [x] Test device → DMZ host: traceroute confirms APP → BT8-gw → transit → thebeyond → DMZ
- [x] **2.6** Document any UCI snippets / kernel-tuning needed in Phase 4 implementation notes
  - Captured in `llm-not../bt8-gateway-as-built.md` (post-2.1 UCI dump
    `temp/BT8-gw-current.uci`, deltas vs Runbook B, and Phase-4 codification targets).

## Phase 3 — Production cutover of office-side VLAN gateways

- [x] **3.1** Physically install BT8-gateway in office production location
- [x] **3.2** Add inert L3 config on BT8-gateway for INFRA (11), HOME (20), LAB (21)
  - [x] Bridge + fw4 zone binding + odhcpd config in place, but bridge has no IP and odhcpd disabled
- [x] **3.3** Per-VLAN cutover (scripted single SSH transaction per VLAN)
  - [x] INFRA (11)
  - [x] HOME (20)
  - [x] LAB (21)
  - [x] Confirm gratuitous ARP convergence (`arping -U`, busybox flag) for each
- [x] **3.4** Apply on `thebeyond`
  - [x] Remove IPv4 + IPv6 gateway addresses from migrated VLAN bridges — done by dropping `management`/`trusted`/`lab` from `subnetBindings` in `hosts/thebeyond/router.nix` (commits `7ad41d7`, `75fd7ef`). Bridges themselves go away with the entries (no separate "keep bridge" step needed — Phase 5 doesn't need them on thebeyond).
  - [x] Confirm `router6.routes` cross-gateway routes still present (`10.97.0.0/16` + `fdc6:55f2:0a5e:1000::/52` via `10.255.255.2`, `router.nix:559-569`; landed in `9f89f95`)
  - [x] Remove `management`, `trusted`, `lab` zones from `router6.zones` + their `mkVlanBridge` entries
  - [x] Keep `app` zone as no-op-by-design (member-only `brVAPP`, no IP/DHCP/rules)
  - [x] Confirm `network`, `dmz`, `transit`, `external`, `ba-tunnel`, `media`, untrusted family kept
  - [x] Remove DHCP definitions for migrated VLANs from Kea (dropped along with `mkVlanBridge` entries — Kea config is derived from `subnetBindings`)
  - [x] Stop DHCPv6-PD server on migrated VLANs (same — derived from removed bindings)
  - [x] **Deviation:** source-zone attribution is lost across the transit /30, so post-Phase-3 admin-VLAN access to thebeyond input and to other zones (DMZ, network/bt8bridge, network/phantasma, untrusted) is gated by **source subnet** under `transit` instead of source-zone under each zone. See `router.nix:428-443` (input), `:450-549` (forwards). Landed in `907e91b`. Will be revisited if/when we add a project-side trust-level wrapper.
- [x] **3.5** Verify connectivity (DMZ ↔ APP ↔ GUEST ↔ INFRA paths; SSH to thebeyond, BT8-bridge, BT8-gateway) — operator verified out-of-band (SSH to all three gateways; HOME → DMZ HTTP; WAN egress).
- [x] **3.6** Re-run external scan runbook (Runbook E) — completed by operator out-of-band.

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

- [x] **5.A** `oracion` (Jellyfin/Navidrome/Retrom) → APP — landed 2026-05-31
  - [x] Re-IP into `10.97.50.52`; registry move (`lib/common/data/network.nix` dmz.hosts → app.hosts)
  - [x] Calvard host plumbing: br50 / enp88s0.50 / vm-50-bridge added (`hosts/calvard/microvm/default.nix`)
  - [x] Oracion microvm tap renamed `vm-100-oracion` → `vm-50-oracion` (`hosts/calvard/microvm/guests/oracion/microvm.nix`)
  - [x] DNS auto-regenerated (phantasma `mkUnboundLocalData` is registry-derived; refreshes on next thebeyond deploy)
  - [x] DMZ host-hardening profile already in place on oracion (egress filter + host firewall predate Phase 5.A; `mkEgressRules zone …` auto-targets new APP gateway)
  - [x] thebeyond router: `media.forwardRules.dmz` oracion → `media.forwardRules.transit` (`hosts/thebeyond/router.nix:347-365`)
  - [x] BT8-gateway fw4: per-flow accepts for wg-media→oracion (transit→app), oracion→basel ACME, oracion→tharbad push (app→management). Broader than checklist line 192 originally said — needs `config forwarding` directives on the zone pairs to fire. Captured in `temp/BT8-gw-phase-5a-additions.uci` + as-built notes Phase 5.A section.
  - [x] In-zone reachability: VLAN 20 (HOME) → 10.97.50.52 direct, retrom.internal, jellyfin.internal (after browser cache flush) all serve
  - [x] oracion → tharbad metrics push working (fluent-bit healed once BT8-gw rule applied)
  - [x] Consumer-host `/etc/hosts` refresh: thebeyond + liberl microvms (bose, ravennue) redeployed. langport refreshed via calvard reboot.
  - [-] wg-media verification (arcus → jellyfin.internal over wg) — deferred; arcus needs additional work to get on-tunnel, tracked in follow-up plan
  - [-] ACME re-issuance verification — passive; rule is in place, will renew when cert cycle hits
- [ ] **5.B** `creil` (Forgejo internal) → APP
  - [ ] Re-IP, DNS, hardening, retest
  - [ ] Translate any wg-\* sources from existing inbound DMZ forward rules
- [ ] **5.C** `zeiss` (Attic) → APP
  - [ ] Re-IP, DNS, hardening, retest
  - [ ] Translate any wg-\* sources
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
- [ ] **Investigate phantasma slow-boot.** Observed during Phase 0b: the microVM took long enough to come up that `dig @10.91.10.10` returned errors for a while after the host reported the VM started. Need to identify which unit is the long pole (likely AdGuard waiting on Unbound, or Unbound waiting on network-online, or DNSSEC trust-anchor setup). Goal: bound startup to <30s or add a `systemd.services.<unit>.serviceConfig.TimeoutStartSec` / dependency ordering so the VM is considered "ready" only when DNS actually answers. Capture timing: `systemd-analyze blame` and `systemd-analyze critical-chain` inside the VM.
- [ ] **Add end-to-end DNS resolution VM test (`tests/modules/router6-dns-resolution.nix`).** Existing coverage (`router6-kresd-config`, `router6-dns-interception`, `router6-listening-sockets`) verifies the generated lua _string_, the DNAT rules, and the listen sockets — but nothing loads the lua into a running kresd and sends a query. That's why the `policy.add` callback signature bug shipped: lua was syntactically valid and the listener was bound, so every test passed even though every real query crashed kresd. Shape: router VM + client VM + a fake authoritative resolver (e.g. `dnsmasq`) on the WAN side; configure `router6.dns.upstream = [<fake>]`; from client `dig some.test @<router>` and assert the expected answer. Also exercise `policy.suffix(policy.DENY, …)` for `localDomain`. Add to `tests/router6.nix` once written. Becomes the regression test for any future failover mechanism we add back.
- [ ] **Fix `hardwareName` rename semantics in `modules/router6/networking.nix`.** The current generator emits `[Match] OriginalName=<hardwareName>` (lines ~115–122). At boot the kernel-assigned name is `eth0` / `enp*s*` — never the operator-supplied logical name — so the match fails and the rename never fires. NixOS's `99-default.link` then applies `NamePolicy=keep kernel database onboard slot path`, leaving the kernel predictable name in place; the `.network` file matches the topology key (logical name) and binds nothing. Symptom: NIC stays `unmanaged` after boot. Workaround in `thebeyond/router.nix`: topology keys renamed to `enp2s0` / `enp4s0` and `hardwareName` dropped (no `.link` emitted at all). Proper fix: switch the `.link` match to `Path=` (PCI path, stable across reboots) or `MACAddress=`, both of which match what the kernel actually exposes pre-rename. Affects every consumer of `hardwareName`, hence module-level. Tackle after Phase 0b closes — restore logical topology keys on `thebeyond` once landed.
