# Dual-Gateway Follow-ups Plan

**Status:** Drafted, not started (some items gated on CI/CD activation).
**Plan date:** 2026-05-31.
**Successor to:** [`llm-notes/done/dual-gateway-app-vlan-plan.md`](../done/dual-gateway-app-vlan-plan.md)
  — that plan shipped the dual-gateway topology (Phases 0–3) and proved
  out APP with `oracion` (Phase 5.A). This plan picks up the remaining
  Phase 5 service migrations, the deferred Phase 4 / 4.5 image-builder
  codification, plus open items that accumulated during the dual-gateway
  window.
**Related:** [`llm-notes/bt8-gateway-as-built.md`](../bt8-gateway-as-built.md)
  remains the living anchor for BT8-gateway state until Phase 4 codifies
  it. [`llm-notes/plans/cicd-fleet-activation-plan.md`](cicd-fleet-activation-plan.md)
  is the gate for Phase 4 / 4.5 (see
  [`project-phase-4-deferred-to-cicd`](../../../../home/mutantmell/.claude/projects/-home-mutantmell-git-dotfiles/memory/project_phase_4_deferred_to_cicd.md)).

---

## Section A — Remaining Phase 5 service migrations (APP)

Same shape as the `oracion` move: re-IP into `10.97.50.x`, registry move
from `dmz.hosts` to `app.hosts`, calvard/erebonia/liberl host plumbing if
needed (br50 already exists on calvard from 5.A), tap-id rename on the
microvm, DMZ host-hardening profile carries through, BT8-gw fw4
additions for any new cross-zone flows.

### A.1 `creil` (Forgejo internal) → APP

- [ ] Re-IP `creil` to `10.97.50.53` (registry move dmz → app)
- [ ] Tap-id rename `vm-100-creil` → `vm-50-creil` (if applicable; check
      `hosts/calvard/microvm/guests/creil/microvm.nix`)
- [ ] BT8-gw fw4 additions:
  - [ ] `transit → app` rule scoping any wg-\* sources currently
        permitted to reach creil in `dmz.forwardRules.*` on thebeyond
        (mirrors the wg-media → oracion pattern from 5.A)
  - [ ] `app → management` rule: creil → basel (ACME), creil → tharbad
        (Loki + metrics push) — same shape as oracion's
- [ ] Remove the post-5.A temp rule `management → creil (SSH + Forgejo)
      [via BT8-gateway]` in `hosts/thebeyond/router.nix` (currently noted
      as `# Remove after Phase 5.B`) — it becomes a BT8-gw-local
      management → app rule once creil is in APP
- [ ] Retest: in-zone, cross-zone (management → creil for Forgejo
      browsing from operator workstation), wg-\* paths
- [ ] Consumer-host `/etc/hosts` refresh: grep for `mkExtraHosts.*creil`
      and redeploy each consumer

### A.2 `zeiss` (Attic) → APP

- [ ] Re-IP `zeiss` to `10.97.50.31` (registry move; preserve host id 31)
- [ ] zeiss lives on liberl, not calvard — liberl needs br50 plumbing
      added (mirrors what calvard got in 5.A.1)
- [ ] BT8-gw fw4 additions:
  - [ ] `transit → app` rule for any wg-\* → zeiss flows
  - [ ] `app → management` rule: zeiss → basel (ACME), zeiss → tharbad
        (push)
- [ ] Retest: nix substitution from a calvard/erebonia/operator client;
      Attic cache push from saint-arkh
- [ ] Consumer-host /etc/hosts refresh

### A.3 `saint-arkh` (CI runners) → APP

- [ ] Re-IP `saint-arkh` to `10.97.50.61` (registry move)
- [ ] saint-arkh lives on erebonia (Incus) — erebonia needs br50
      plumbing
- [ ] BT8-gw fw4 additions:
  - [ ] `app → management` rule: saint-arkh → basel (ACME), → tharbad
        (push)
  - [ ] `app → dmz` flows: if saint-arkh → langport/trista/etc. flows
        exist, add `transit → dmz` rule on thebeyond scoped to
        saint-arkh source IP (matches the dmz/transit pattern set up
        for tharbad → DMZ-resident node_exporters in Phase 3.4)
  - [ ] `app → app` flows: saint-arkh → zeiss for Attic cache pushes
        once zeiss is also in APP (handled by zone-pair `app → app`
        forwarding; intra-zone allowed by default — verify)
- [ ] Retest: a sample CI job that exercises Forgejo (creil), Attic
      (zeiss), and the public-facing langport reverse-proxy path

### A.4 Post-migration cleanup (was 5.E–J)

After A.1–A.3 land — the only remaining DMZ residents are `langport`
and `trista`, both physically pinned to DMZ for their roles (public
ingress + SSH bastion). The renumber unwinds the temporary
`prefix4 = "10.97.100"` override on the `dmz` zone.

- [ ] Drop `prefix4 = "10.97.100"` override on `dmz` zone in
      `lib/common/data/network.nix`
- [ ] Re-IP `langport` to `10.91.100.41` (dual-stack window pattern —
      add new address alongside, switch DNS, drop old)
- [ ] Re-IP `trista` to `10.91.100.51` (same dual-stack approach)
- [ ] Update `thebeyond`'s `dmz` bridge to `10.91.100.1/24`
- [ ] Check `basel`'s step-ca issuance templates; re-issue any cert
      pinning `10.97.100.<id>`
- [ ] Confirm Cloudflare DNS for `langport`'s WAN side unaffected by
      the internal re-IP

---

## Section B — Phase 4 / 4.5 (CI/CD-gated)

**Gate:** Phase 4 is deferred until
[`cicd-fleet-activation-plan.md`](cicd-fleet-activation-plan.md) is
complete. Reason: image-build cutover gets materially safer once image
deploys are automated rather than hand-pushed. See
[`project-phase-4-deferred-to-cicd`](../../../../home/mutantmell/.claude/projects/-home-mutantmell-git-dotfiles/memory/project_phase_4_deferred_to_cicd.md).

### B.1 — Codify BT8-gateway and BT8-bridge in Image Builder

Source for the gateway "golden output":
[`../bt8-gateway-as-built.md`](../bt8-gateway-as-built.md)
+ `temp/BT8-gw-current.uci` + `temp/BT8-gw-phase-5a-additions.uci`. The
gateway type should produce UCI substantially identical to those files
as a snapshot test.

- [ ] Extend `lib/common/data/openwrt.nix`: add BT8 target/subtarget;
      pin Image Builder hash via `--update-pins`
- [ ] Audit `meshVlans` table — every batman-trunked VLAN is now a mesh
      VLAN
- [ ] Define `wirelessBridge` type (flat L2 bridge across wired uplink
      + batman-adv mesh)
- [ ] Define `gateway` type (per-VLAN bridges, fw4 zones, odhcpd,
      batman participation, optional client APs)
- [ ] Extend `meshAP` type to accept BT8 hardware
- [ ] Generate fw4 UCI from structured zone description in Nix
- [ ] Generate odhcpd UCI per VLAN from registry data
- [ ] Pure-Nix evaluation snapshot tests under `tests/openwrt/`,
      gating against the as-built `.uci` files
- [ ] Cutover devices one at a time:
  - [ ] BT8-bridge — capture manual UCI as backup, build, deploy
  - [ ] BT8-gateway — capture manual UCI as backup, build, deploy

### B.2 — Lock down BT8-gateway/BT8-bridge management plane

- [ ] Decide management-host allowlist (operator workstation IPs on
      `network`/`management`, pusher host from CI/CD work) and document
      in OpenWrt zone description
- [ ] Add `inputRules` restriction: drop SSH (22) + LuCI (80/443) from
      sources outside allowlist
- [ ] Build new image with lockdown:
  - [ ] Dry-run via runtime UCI on BT8-gateway (`fw4 reload`)
  - [ ] Confirm operator can still SSH; revert runtime change
- [ ] Deploy image-built lockdown to BT8-gateway first; verify; then
      BT8-bridge
- [ ] Capture pre-lockdown UCI as rollback artifact

### B.3 — Revisit broad zone-pair forwarding directives

Phase 5.A added `config forwarding` directives for `transit → app` and
`app → management` on BT8-gw because fw4 won't fire per-rule accepts
without them. The per-rule entries document intent but don't tighten
the zone-pair policy itself on this fw4 version.

- [ ] As Phase 5.B–D and Phase 4.1 add more per-flow rules, evaluate
      whether to refactor into custom chains or per-rule defaults that
      give back strict-by-default at the zone-pair level. May be a
      no-op if the per-flow list stays small.

---

## Section C — Microvm MACVLAN migration

**Background:** the current microvm hosts (calvard, erebonia, liberl)
attach guests via tap interfaces bridged into per-VLAN Linux bridges
(`br11`, `br21`, `br50`, `br100`). MACVLAN attaches each guest as a
discrete sub-device on the parent VLAN interface, eliminating the
bridge plus its `br_netfilter` surface, STP state, and MAC learning
overhead. microvm.nix supports `macvtap` natively.

**Why not bundled into 5.A:** orthogonal to the gateway migration;
adding it would muddle 5.A's rollback story. Per
[`microvm-host-no-guest-l2`](../../../../home/mutantmell/.claude/projects/-home-mutantmell-git-dotfiles/memory/project_microvm_host_no_guest_l2.md),
the main MACVLAN concern (host↔child L2 isolation) is not actually a
blocker for this fleet — hosts don't initiate to their own guests.

### C.1 Design

- [ ] Pick MACVLAN mode: default `bridge` (guest↔guest within parent
      interface allowed) vs. `vepa` (forces traffic out the parent for
      switch-side hairpin) vs. `private` (guests fully isolated). Most
      likely `bridge` — preserves intra-VLAN guest-to-guest flows
      without bouncing off the switch.
- [ ] Document fallback: if a future host↔guest L2 flow is ever
      needed, an extra macvlan on the host side recovers it without
      reverting the whole design.
- [ ] Confirm BT8-gw / arseille / upstream switches handle the
      per-guest MACs cleanly (CAM table headroom, no DHCP snooping
      surprises).

### C.2 Conversion

Per-host conversion (each host independent):

- [ ] **calvard** — convert all guests in `hosts/calvard/microvm/guests/*`;
      remove `20-br*` bridge netdevs and `20-vm*-bridge` networks from
      `hosts/calvard/microvm/default.nix`; switch each guest's
      `microvm.interfaces` from `type = "tap"` to `type = "macvtap"`
      with `link = "enp88s0.<vid>"`. Verify each guest's L2/L3
      reachability post-deploy.
- [ ] **erebonia** — same shape for Incus VMs (`saint-arkh`, `trista`,
      `roer`). Incus has its own interface model; verify macvlan
      attachment works through the Incus profile.
- [ ] **liberl** — for microVM guests (`bose`, `ravennue`, future
      `zeiss` post-Phase-5.C).

### C.3 Tests

- [ ] Pure-eval test that the bridge netdevs are gone from the host
      configs
- [ ] VM test that boots a microvm with macvtap and confirms basic L2
      forwarding (or accept that NixOS upstream coverage is enough)

---

## Section D — Open items inherited from dual-gateway plan

### D.1 Hardware decommissioning

- [ ] Last E8450 mesh AP decommission. Tracked separately; optional —
      previously stalled because BT8 mesh coverage was sufficient.
      Revisit when there's a reason to reduce device count.

### D.2 Network gear into the flake

- [ ] OpenWRT homelab L2 switch (switch behind BT8-gateway) into the
      flake. Wiring follows the `arseille` pattern (per
      [`project-arseille-netmgmt-migration`](../../../../home/mutantmell/.claude/projects/-home-mutantmell-git-dotfiles/memory/project_arseille_netmgmt_migration.md)).
      Gives `netmgmt.hosts` its first non-arseille consumer; trunks
      NETMGMT/12 to BT8-gateway (resolves the
      [as-built-notes loose-end](../bt8-gateway-as-built.md)).
- [ ] `arseille` flake back-port (already underway as a hand-driven
      migration). When `network.hosts.arseille = 12` moves to
      `netmgmt.hosts.arseille = 12` and the `vlanId` in
      `hosts/openwrt/arseille.nix` flips from 10 → 12, the live state
      and flake state will be in sync.

### D.3 CI/CD ancillary placement

- [ ] Pusher host zone placement. The CI/CD activation plan creates a
      pusher host that runs `nixos-rebuild --target-host`; its zone
      placement affects the Phase 4.5 management-host allowlist. Decide
      when the CI/CD plan reaches that step.

### D.4 Hostile-zone tightening

- [ ] HA host on IoT VLAN — once Home Assistant is registered, tighten
      transit `forwardRules.iot` (currently absent — relies on the
      broader `forwardRules.untrusted`) to HA host IP + port 8123 only.
      See `hosts/thebeyond/router.nix:545-549` for the comment marking
      the current state.

### D.5 Router resilience / observability

- [ ] **Investigate phantasma slow-boot.** Observed during Phase 0b:
      `dig @10.91.10.10` returned errors for a while after thebeyond
      reported the VM started. Identify the long-pole unit (likely
      Blocky-on-Unbound dependency, Unbound-on-network-online, or
      DNSSEC trust-anchor setup). Goal: bound startup to <30s or add
      `systemd.services.<unit>.serviceConfig.TimeoutStartSec` /
      dependency ordering so the VM is considered "ready" only when
      DNS actually answers. Capture timing: `systemd-analyze blame`
      and `systemd-analyze critical-chain` inside the VM.
- [ ] **Add end-to-end DNS resolution VM test
      (`tests/modules/router6-dns-resolution.nix`).** Existing
      coverage (`router6-kresd-config`, `router6-dns-interception`,
      `router6-listening-sockets`) verifies the generated lua _string_,
      the DNAT rules, and the listen sockets — but nothing loads the
      lua into a running kresd and sends a query. That's why the
      `policy.add` callback signature bug shipped: lua was
      syntactically valid and the listener was bound, so every test
      passed even though every real query crashed kresd. Shape: router
      VM + client VM + fake authoritative resolver (e.g. `dnsmasq`) on
      the WAN side; configure `router6.dns.upstream = [<fake>]`; from
      client `dig some.test @<router>` and assert the expected answer.
      Also exercise `policy.suffix(policy.DENY, …)` for `localDomain`.

### D.6 Router6 module hygiene

- [ ] **Fix `hardwareName` rename semantics in
      `modules/router6/networking.nix`.** Current generator emits
      `[Match] OriginalName=<hardwareName>` (~lines 115–122); at boot
      the kernel-assigned name is `eth0`/`enp*s*` — never the
      operator-supplied logical name — so the match fails, the rename
      never fires, and NixOS's `99-default.link` leaves the kernel
      predictable name in place. The `.network` file matches the
      topology key and binds nothing. Symptom: NIC stays `unmanaged`
      after boot. Workaround in `thebeyond/router.nix`: topology keys
      use kernel names directly (`enp2s0`/`enp4s0`) and `hardwareName`
      is dropped — see
      [`feedback-no-hardwarename`](../../../../home/mutantmell/.claude/projects/-home-mutantmell-git-dotfiles/memory/feedback_no_hardwarename.md).
      Proper fix: switch the `.link` match to `Path=` (PCI path, stable
      across reboots) or `MACAddress=`, both of which match what the
      kernel exposes pre-rename. Module-level change; affects every
      consumer of `hardwareName`. Once landed, restore logical topology
      keys on `thebeyond`.

---

## Section E — Deferred from 5.A

- [ ] **arcus on-tunnel + wg-media → oracion verification.** arcus
      needs additional work to get on-tunnel (its own follow-up); once
      that's done, confirm `curl -kI https://jellyfin.internal/`
      succeeds from arcus over wg-media. Validates the Phase 5.A
      `transit → app` BT8-gw rule from the client side.

---

## Sequencing notes

- **Section A** (service migrations) can proceed without waiting on
  CI/CD. Each move is independent; pick the order based on operator
  convenience.
- **Section B** (Phase 4 / 4.5) is gated on CI/CD activation.
  `cicd-fleet-activation-plan.md` is the predecessor.
- **Section C** (MACVLAN) is independent of A and B; pick a quiet
  window since it touches every microvm guest.
- **Section D** items are bite-sized and can be slotted in
  opportunistically.
- **Section E** lifts as soon as arcus is back on-tunnel.
