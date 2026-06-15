# Dual-Gateway Follow-ups Plan

**Status:** WIP. Section A service moves are complete in the flake; Section B
and most Section C follow-ups remain.
**Plan date:** 2026-05-31.
**Successor to:** [`llm-notes/done/dual-gateway-app-vlan-plan.md`](../done/dual-gateway-app-vlan-plan.md)
— that plan shipped the dual-gateway topology (Phases 0–3) and proved
out APP with `oracion` (Phase 5.A). This plan picks up the remaining
Phase 5 service migrations, the deferred Phase 4 / 4.5 image-builder
codification, plus open items that accumulated during the dual-gateway
window.
**Related:** [`llm-notes/guides/bt8-gateway-as-built.md`](../guides/bt8-gateway-as-built.md)
remains the living anchor for BT8-gateway state until Phase 4 codifies
it. [`llm-notes/plans/cicd-fleet-activation-plan.md`](../plans/cicd-fleet-activation-plan.md)
is the gate for Phase 4 / 4.5 (see
[`project-phase-4-deferred-to-cicd`](../../../../home/mutantmell/.claude/projects/-home-mutantmell-git-dotfiles/memory/project_phase_4_deferred_to_cicd.md)).

---

## Section A — Remaining Phase 5 service migrations (APP) — COMPLETE

Same shape as the `oracion` move: re-IP into `10.97.50.x`, registry move
from `dmz.hosts` to `app.hosts`, calvard/erebonia/liberl host plumbing if
needed (br50 already exists on calvard from 5.A), tap-id rename on the
microvm, DMZ host-hardening profile carries through, BT8-gw fw4
additions for any new cross-zone flows.

### A.1 `creil` (Forgejo internal) → APP — DONE

- [x] Re-IP `creil` to `10.97.50.53` (registry move dmz → app)
- [x] Tap-id rename `vm-100-creil` → `vm-50-creil` (if applicable; check
      `hosts/calvard/microvm/guests/creil/microvm.nix`)
- [x] BT8-gw fw4 additions:
  - [x] `transit → app` rule scoping any wg-\* sources currently
        permitted to reach creil in `dmz.forwardRules.*` on thebeyond
        (mirrors the wg-media → oracion pattern from 5.A)
  - [x] `app → management` rule: creil → basel (ACME), creil → tharbad
        (Loki + metrics push) — same shape as oracion's
- [x] Remove the post-5.A temp rule `management → creil (SSH + Forgejo)
  [via BT8-gateway]` in `hosts/thebeyond/router.nix` (currently noted
      as `# Remove after Phase 5.B`) — it becomes a BT8-gw-local
      management → app rule once creil is in APP
- [x] Retest: in-zone, cross-zone (management → creil for Forgejo
      browsing from operator workstation), wg-\* paths
- [x] Consumer-host `/etc/hosts` refresh: grep for `mkExtraHosts.*creil`
      and redeploy each consumer

### A.2 `zeiss` (Attic) → APP — DONE

- [x] Re-IP `zeiss` to `10.97.50.31` (registry move; preserve host id 31)
- [x] zeiss lives on liberl, not calvard — liberl needs br50 plumbing
      added (mirrors what calvard got in 5.A.1)
- [x] BT8-gw fw4 additions:
  - [x] `transit → app` rule for any wg-\* → zeiss flows
  - [x] `app → management` rule: zeiss → basel (ACME), zeiss → tharbad
        (push)
- [x] Retest: nix substitution from a calvard/erebonia/operator client;
      Attic cache push from saint-arkh
- [x] Consumer-host /etc/hosts refresh

### A.3 `saint-arkh` (CI runners) → APP — DONE

- [x] Re-IP `saint-arkh` to `10.97.50.61` (registry move)
- [x] saint-arkh lives on erebonia as a **microVM**, not Incus. Its APP
      attachment is bridge-free macvtap on `uplink.50`
      (`hosts/erebonia/microvm/guests/saint-arkh/microvm.nix`), with the
      host-side carrier defined in `hosts/erebonia/microvm/default.nix`.
- [x] BT8-gw fw4 additions:
  - [x] `app → management` rule: saint-arkh → basel (ACME), → tharbad
        (push)
  - [x] `app → dmz` flows: if saint-arkh → langport/trista/etc. flows
        exist, add `transit → dmz` rule on thebeyond scoped to
        saint-arkh source IP (matches the dmz/transit pattern set up
        for tharbad → DMZ-resident node_exporters in Phase 3.4)
  - [x] `app → app` flows: saint-arkh → zeiss for Attic cache pushes
        once zeiss is also in APP (handled by zone-pair `app → app`
      forwarding; intra-zone allowed by default — verify)
- [x] Retest: a sample CI job that exercises Forgejo (creil), Attic
      (zeiss), and the public-facing langport reverse-proxy path

### A.4 Post-migration cleanup (was 5.E–J) — DONE 2026-06-01

After A.1–A.3 land — the only remaining DMZ residents are `langport`
and `trista`, both physically pinned to DMZ for their roles (public
ingress + SSH bastion). The renumber unwinds the temporary
`prefix4 = "10.97.100"` override on the `dmz` zone.

Operator is sole consumer of langport + trista, so the dual-stack
window was skipped in favor of a single in-place flip.

- [x] Drop `prefix4 = "10.97.100"` override on `dmz` zone in
      `lib/common/data/network.nix`
- [x] Re-IP `langport` to `10.91.100.41` (single in-place flip via
      registry — langport already consumed `host.cidr4`/`zone.gateway4`)
- [x] Re-IP `trista` to `10.91.100.51` (migrated hardcoded literals to
      registry helpers in `hosts/erebonia/incus/guests/trista/default.nix`
      while in there; eliminates the divergence call-out)
- [x] Update `thebeyond`'s `dmz` bridge to `10.91.100.1/24` (automatic
      via registry — router topology re-derived from `net.networks.dmz`)
- [x] Check `basel`'s step-ca issuance templates; re-issue any cert
      pinning `10.97.100.<id>` — **no reissuance needed.** Audited all
      cert-request sites in the flake (`messeldam/keycloak.nix:86`,
      `roer/api.nix:87`, `modules/common/fluent-bit.nix:144`); all
      DNS-only. All 18 checked-in fleet x5c enrollment certs are
      DNS-only. step-ca policy at `basel/modules/step-ca.nix:55`
      allows IP SANs in `10.97.0.0/16`, but the flake doesn't exercise
      that path.
- [x] Confirm Cloudflare DNS for `langport`'s WAN side unaffected by
      the internal re-IP — external DNS untouched by definition (only
      internal addressing changed).
- [x] Verify: `dig langport.internal` returns `10.91.100.41` from
      edith — confirmed 2026-06-01 03:28 UTC. trista reachable
      via SSH on the new IP; langport public HTTPS ingress confirmed
      operational; no regressions observed elsewhere.

Also bundled into this section's PR: kresd-isp-fallback runtime-dir
preservation fix (`modules/router6/dns-isp-fallback.nix`). Stops
kresd@N restarts from wiping `/run/knot-resolver/isp-dns.lua` —
unrelated to the re-IP but rode the same deploy window.

Erebonia deployd bridge (kata-runtime workload pool) also re-derived
from the registry in this PR — previously hardcoded `10.97.100.x`
literals at `hosts/erebonia/default.nix:38-41`. Same shape as the
trista cleanup.

---

## Section B — Phase 4 / 4.5 (CI/CD-gated)

**Gate:** Phase 4 is deferred until
[`cicd-fleet-activation-plan.md`](../plans/cicd-fleet-activation-plan.md) is
complete. Reason: image-build cutover gets materially safer once image
deploys are automated rather than hand-pushed. See
[`project-phase-4-deferred-to-cicd`](../../../../home/mutantmell/.claude/projects/-home-mutantmell-git-dotfiles/memory/project_phase_4_deferred_to_cicd.md).

### B.1 — Codify BT8-gateway and BT8-bridge in Image Builder

Source for the gateway "golden output":
[`../guides/bt8-gateway-as-built.md`](../guides/bt8-gateway-as-built.md)

- `temp/BT8-gw-current.uci` + `temp/BT8-gw-phase-5a-additions.uci`. The
  gateway type should produce UCI substantially identical to those files
  as a snapshot test.

* [ ] Extend `lib/common/data/openwrt.nix`: add BT8 target/subtarget;
      pin Image Builder hash via `--update-pins`
* [ ] Audit `meshVlans` table — every batman-trunked VLAN is now a mesh
      VLAN
* [ ] Define `wirelessBridge` type (flat L2 bridge across wired uplink + batman-adv mesh)
* [ ] Define `gateway` type (per-VLAN bridges, fw4 zones, odhcpd,
      batman participation, optional client APs)
* [ ] Extend `meshAP` type to accept BT8 hardware
* [ ] Generate fw4 UCI from structured zone description in Nix
      — **subsumes the deferred cluster-VLAN-51 C.7 capture**: the
      `cluster` zone + egress allowlist (currently the hand-maintained
      "Cluster VLAN 51 additions" in the as-built note) becomes flake
      source here, and the snapshot test records which mechanism enforces.
      Egress behaviour is already proven (oracion/saint-arkh denied,
      creil/zeiss allowed — see the as-built enforcement table and
      [`workload-network-isolation-plan.md`](workload-network-isolation-plan.md)
      Acceptance).
* [ ] Generate odhcpd UCI per VLAN from registry data
* [ ] Pure-Nix evaluation snapshot tests under `tests/openwrt/`,
      gating against the as-built `.uci` files
* [ ] Cutover devices one at a time:
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

### B.4 — Move liberl's wg-ba backup tunnel onto BT8-gateway

Relocated from `wg-ba-liberl-backup-tunnel-plan.md` (done/) Future #2. Once
BT8-gateway is codified in the Image Builder (B.1) and the management-WAN egress
drops to zero, move liberl's offsite backup tunnel from the host onto
BT8-gateway — liberl's actual default gateway — so liberl emits zero WAN packets.
Today it's a per-host `wg-quick` tunnel (`hosts/liberl/wg-ba.nix`).

- [ ] On BT8-gw (OpenWRT): UCI WireGuard interface to the offsite remote, with
      native netifd DDNS re-resolution + the endpoint injected via the
      `--secrets-file` build path
- [ ] Scoped fw4 egress for liberl → the backup target; liberl reaches it
      internally via its gateway
- [ ] On liberl: remove `hosts/liberl/wg-ba.nix` (one file + import) + its sops
      secrets + the tunnel-scoped egress table
- [ ] Remote operator: re-peer to BT8-gw (new pubkey + AllowedIPs) instead of
      liberl

Contingencies: BT8-gw under declarative management (B.1); confirm BT8 WG
throughput is a non-issue (likely — offsite backup is WAN-upload-bound).

---

## Section C — Microvm MACVLAN migration

**Background:** the remaining bridge-backed microvm hosts attach some guests via
tap interfaces bridged into per-VLAN Linux bridges (for example `br21`, `br50`,
or `br100`, depending on host). MACVLAN attaches each guest as a
discrete sub-device on the parent VLAN interface, eliminating the
bridge plus its `br_netfilter` surface, STP state, and MAC learning
overhead. microvm.nix supports `macvtap` natively.

**Why not bundled into 5.A:** orthogonal to the gateway migration;
adding it would muddle 5.A's rollback story. Per
[`microvm-host-no-guest-l2`](../../../../home/mutantmell/.claude/projects/-home-mutantmell-git-dotfiles/memory/project_microvm_host_no_guest_l2.md),
the main MACVLAN concern (host↔child L2 isolation) is not actually a
blocker for this fleet — hosts don't initiate to their own guests.

**Status refresh (2026-06-15):** the earlier `saint-arkh` macvtap blocker is
closed. Current repo state has:

- `saint-arkh` as an erebonia **microVM** on APP/VLAN 50, using
  `type = "macvtap"`, `id = "vm-50-s-arkh"`, `macvtap.link = "uplink.50"`,
  and `macvtap.mode = "bridge"`.
- erebonia host networking defining standalone, host-IP-less macvtap carriers
  for `uplink.50`, `uplink.51`, and `uplink.100`, with no `br50`/`br51`/`br100`.
- **No current erebonia guest uses VLAN 21.** `br21`/`uplink.21` were leftover
  lab plumbing on erebonia, not a blocker. The current lab guests are elsewhere
  (`edith` on calvard Incus; `bose`/`ravennue` on liberl microVMs).
- **Update (2026-06-15):** erebonia's VLAN 11 bridge has also been retired in
  code. The management IP now lives directly on `uplink.11`; future VLAN 11
  guests should attach as host-IP-less `vm-11-*` macvtap/macvlan children.
  The unused VLAN 21 lab bridge/subinterface was removed from erebonia.
- KubeVirt dev machines using the same bridge-free lesson on VLAN 51: one shared
  `cluster-vlan51` macvtap NAD over `uplink.51`, plus the KubeVirt macvtap
  binding plugin.

So Section C no longer starts with "fix saint-arkh"; saint-arkh is the
working example. The remaining work is to generalize the bridge-free pattern to
the bridge-backed microVM guests that still exist on other hosts/VLANs and
choose `bridge`/`vepa`/`private` per trust boundary.

### C.1 Design

- [x] Pick initial MACVLAN mode: `bridge` for the existing saint-arkh APP
      placement. Keep `vepa`/`private` as per-zone hardening choices for future
      conversions where same-host sibling isolation matters.
- [ ] For each future conversion, confirm whether to keep `bridge` (guest↔guest within parent
      interface allowed) vs. `vepa` (forces traffic out the parent for
      switch-side hairpin) vs. `private` (guests fully isolated).
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
- [x] **erebonia** — current guest networking no longer needs host bridges.
      `saint-arkh` is already a microVM on
      macvtap/APP (`uplink.50`), and VLAN 51 KubeVirt dev machines use macvtap
      over `uplink.51`. The host management address now lives directly on
      `uplink.11`, with a host-IP-less `vm-11-*` match available for future
      macvtap/macvlan guests. The unused `br21`/`uplink.21`/`vm-21-*` lab
      plumbing is removed. Trista is already Incus macvlan on `uplink.100` and
      migrates separately through the Incus-workstation/KubeVirt plan rather
      than through this microVM-only conversion.
- [ ] **liberl** — for microVM guests (`bose`, `ravennue`, future
      `zeiss` post-Phase-5.C).

### C.3 Tests

- [ ] Pure-eval test that the bridge netdevs are gone from the host
      configs
- [ ] VM test that boots a microvm with macvtap and confirms basic L2
      forwarding (or accept that NixOS upstream coverage is enough)

### C.4 — liberl host-firewall tightening (enabled by the rework)

Relocated from `wg-ba-liberl-backup-tunnel-plan.md` (done/) Future #1. Removing
liberl's bridge/`br_netfilter` surface (C.2) makes a strict whole-host firewall
tractable; this also lands with the management-WAN egress drop (Section B gate).
Today only liberl's wg-ba _tunnel_ egress is filtered (`hosts/liberl/wg-ba.nix`'s
`wgBa` table) — this generalizes it to the whole host.

- [ ] liberl ingress → NFS + SMB only (retire the broad SSH-from-gateway allow
      once a management access path is settled)
- [ ] liberl egress → default-drop allowlist via `mkEgressFilter` (DNS, NTP,
      fluent-bit→tharbad, internal attic/`zeiss` substituter, the wg-ba
      transport; the existing over-tunnel rule folds in)

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
      [as-built-notes loose-end](../guides/bt8-gateway-as-built.md)).
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

- [x] ~~Investigate phantasma slow-boot.~~ Closed 2026-05-31. Slow boot
      is the accepted cost of running phantasma as a full systemd NixOS
      environment — a deliberate trade-off, not a defect. The
      user-visible impact during planned reboots is already bounded by
      the kresd ISP-lease fallback breaker (see
      `modules/router6/dns.nix` strict-failover dispatcher), which
      switches to ISP DNS within ~10–15s of phantasma going unhealthy
      and recovers ~6–8s after blocky binds. Diagnosis on three real
      trip events (May 28–31) confirmed the breaker behaves correctly
      and every trip mapped 1:1 to a planned dual-gateway-work reboot.
- [x] ~~Fix thebeyond timezone — should be UTC, not PDT.~~ Done
      2026-05-31. `hosts/thebeyond/default.nix:46` flipped from
      `America/Los_Angeles` → `UTC`. Bundled into the phantasma-journald
      deploy.
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
