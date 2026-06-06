# DNS Consolidation — Plan

Replaces the former `dns-upgrades-plan.md` (deleted): its Phase 1 (kresd
ISP-lease fallback) is deployed and recorded in
`modules/router6/dns-isp-fallback.nix` + the code and
[[project_kresd_fallback_handles_phantasma_reboots]]; its Phase 3
(`sourceRoutes` bypass) was removed for the cache leak described below; and
its target architecture — kresd → Blocky → Unbound on phantasma — is what
this plan moves away from.

## Where we are now

After the Blocky-removal work (commit `035f628`):

```
client → DNAT → thebeyond:kresd  (front, strict-failover breaker, cache)
                     │ primary           │ fallback
                     ▼                   ▼
              phantasma:Unbound      ISP resolvers
              (recursive + DNSSEC + split-horizon .internal)
```

- **No ad-blocking anywhere** — Blocky was removed because the per-VLAN
  `sourceRoutes` bypass leaked blocks across clients. Root cause: kresd's
  cache is keyed on `(qname,qtype,qclass)` with no source/upstream
  dimension, and `sourceRoutes` only chose a different *upstream* on a
  cache *miss*. A block cached from any client was served to the exempt
  VLAN. See [[project_guest_vlan_blocky_bypass]].
- The `router6.dns.sourceRoutes` option and its kresd `view.rule_src`
  rendering are gone.

## The principle this plan is built on

Blocking must be a **per-request answer policy evaluated with the client's
identity, in front of every cache** — never a choice of which cached
upstream to consult. A shared cache may only hold the *clean* answer;
blocking is a per-client overlay on top. That means:

1. The blocker (Blocky) goes **in front**, sees real client IPs, and
   applies per-client blocking before its own cache. Its cache stores only
   clean upstream answers.
2. Nothing that caches or strips client IP may sit **in front of** Blocky.
   kresd therefore moves **behind** Blocky.

## Decisions (made with the user)

| Question | Decision |
| --- | --- |
| Recursive resolver | **kresd** (drop Unbound). Both are peers; keeping kresd avoids re-plumbing router6, and kresd's trust-anchor fragility is already mitigated by the pinned read-only `root.key`. |
| Blocking mechanism | **Blocky in front**, as an optional router6 feature, per-interface configurable via `clientGroupsBlock`. |
| Blocky location | **thebeyond** (the always-up router), not phantasma — keeps the front resolver alive across any backend outage. |
| phantasma | **Removed** in Piece 2 once kresd recurses + serves local-data. |
| Blocking polarity | **Block by default, per-interface opt-out** (matches the old GUEST/30 intent). |

## Target architecture

```
client → DNAT → thebeyond:Blocky        (front: per-client blocklist overlay)
                     │  default group → [ads];  opt-out subnets → []
                     ▼ upstream 127.0.0.1#5353
                thebeyond:kresd          (loopback backend: recursion +
                     │                    DNSSEC + authoritative .internal)
                     ▼ on recursion stall
                ISP resolvers (optional fallback, from WAN lease)
```

One box (thebeyond), three concerns cleanly separated: Blocky = blocklist
overlay; kresd = recursion + DNSSEC + authoritative local zones; ISP
fallback = recursion-stall safety net.

---

# Piece 1 — `router6.dns.blocking` feature (Blocky in front)

**Outcome:** restores ad-blocking, leak-free and per-interface. kresd keeps
forwarding to phantasma for now (Piece 1 is purely "insert Blocky in
front"); independently deployable and testable.

### 1a — kresd retreats to a loopback backend  *(NOT STARTED)*

`modules/router6/dns.nix`: when blocking is enabled, kresd stops binding the
client-facing gateway IPs and listens on a loopback backend only
(`127.0.0.1:5353` + `[::1]:5353`). When disabled, current behaviour
(kresd on the zone gateways from `dnsInterfaces`) is unchanged.

- Add `router6.dns.backendPort` (default `5353`) or derive internally.
- `listenPlain` becomes conditional on `cfg.dns.blocking.enable`.

### 1b — `router6.dns.blocking` option surface  *(NOT STARTED)*

Keep the module generic (no project specifics — denylist sources and
conditional domains are passed in by the host):

```nix
router6.dns.blocking = {
  enable = mkEnableOption "Blocky ad-blocking in front of the resolver";
  denylists = mkOption {            # group name → list of store paths
    type = attrsOf (listOf path);   # NEVER https URLs — see
    default = {};                   # [[feedback_blocky_denylists_pinned]]
  };
  defaultGroups = mkOption {        # groups applied to un-exempted clients
    type = listOf str; default = ["ads"];
  };
  conditionalDomains = mkOption {   # domains Blocky must forward, not NXDOMAIN
    type = listOf str; default = [];# (RFC 6761 special-use; .internal etc.)
  };                                # see [[project_blocky_special_use_internal]]
};
```

Per-interface opt-out lives on the topology interface (generic):

```nix
topology.<iface>.network.dns.block = mkOption {
  type = bool; default = true;   # false = this subnet bypasses the blocklist
};
```

### 1c — Render Blocky from the topology  *(NOT STARTED)*

New `modules/router6/dns-blocking.nix` (mkIf `cfg.dns.blocking.enable`):

- **Listeners:** bind every `dnsInterfaces` gateway IPv4/IPv6 on `:53`,
  **plus** `127.0.0.1:53` / `[::1]:53` (the router's own libc). NOT
  `0.0.0.0` — keep loopback:5353 free for kresd.
- **Upstream:** `default → ["127.0.0.1:5353"]` (kresd backend).
- **clientGroupsBlock:** `default = cfg.dns.blocking.defaultGroups`; for each
  interface with `network.dns.block = false`, map its `subnet4`/`subnet6`
  to `[]` (no lists). *Verify Blocky accepts a CIDR key with an empty
  group list = "no blocking"; if not, define a named empty "noblock" group
  and map the CIDRs to it.*
- **denylists:** `cfg.dns.blocking.denylists`.
- **conditional.mapping:** each `conditionalDomains` entry → upstream
  (`127.0.0.1:5353`), `fallbackUpstream = false`.
- **http/metrics:** `127.0.0.1:4000` (loopback only), Prometheus on.

### 1d — Interception retarget  *(NOT STARTED)*

`modules/router6/firewall.nix`: when blocking is enabled, the DNS
interception DNAT target is Blocky's front address (same gateway/host IP
Blocky now binds) instead of kresd. The phantasma source/dest excludes
stay (kresd still forwards to phantasma in Piece 1).

### 1e — thebeyond wiring  *(NOT STARTED)*

`hosts/thebeyond/router.nix`:

```nix
router6.dns.blocking = {
  enable = true;
  denylists.ads = ["${pkgs.mmell.stevenblack-hosts}/hosts"];
  conditionalDomains = ["internal" "internal.mutantmell.net" "mutantmell.net"];
};
# GUEST/30 opt-out:
topology.<guest-iface>.network.dns.block = false;
```

`hosts/thebeyond/default.nix`: add Blocky state to impermanence persist
(`/var/lib/private/blocky`, DynamicUser backing dir) — host-level, not the
generic module.

### 1f — Tests  *(NOT STARTED)*

New real-Blocky+real-kresd VM test — **the regression the old design
failed**: query the *same* ads-listed domain from a blocked client and from
an opt-out client; assert blocked client gets the block AND opt-out client
gets the real answer, in **both orders** (prove neither poisons the other).
Also: split-horizon `.internal` resolves through Blocky→kresd; router's own
libc resolves; metrics endpoint loopback-only.

---

# Piece 2 — kresd recursive + remove phantasma

**Outcome:** kresd recurses directly, holds the authoritative local zones,
and phantasma + Unbound are deleted. Depends on Piece 1 (Blocky is the
front; kresd is the loopback backend whose *internals* change here).

### 2a — `mkKresdLocalData` generator + split-horizon  *(NOT STARTED)*

**Spike first** (real-kresd VM test, per
[[feedback_kresd_ipv6_upstream_no_brackets]] — validate kresd syntax with a
running kresd, not string-eval). kresd 5.x has no built-in authoritative
server; replicate Unbound's three behaviours via `hints` + `policy`:

- `internal.` / `internal.mutantmell.net.` — **static** (authoritative;
  NXDOMAIN unknown in-zone): specific `policy.ANSWER` records, then a
  catch-all NXDOMAIN for the suffix (order matters).
- `mutantmell.net.` — **transparent** (local overrides, recurse the rest):
  `policy.ANSWER` for overridden names only; no catch-all.
- Everything else: native recursion.

Then add `net.mkKresdLocalData` / `mkKresdAliasData` in
`lib/common/data/network.nix` mirroring the Unbound helpers, emitting the
spiked shape. Decide whether to add reverse PTRs now (Unbound's config
doesn't emit them today) or defer.

### 2b — kresd does recursion + fallback rework  *(NOT STARTED)*

`modules/router6/dns.nix`:

- Drop the forward-to-phantasma primary; kresd recurses natively. Keep
  `enableDNSSEC = true` (pinned `root.key` already loaded — kresd now
  actually validates).
- **Retire the phantasma-probe breaker** (its job was surviving phantasma
  reboots; there's no remote primary anymore).
- **Decide the fallback** (recommended: keep one): the original incident
  that motivated fallback was a *recursion* stall (infra-host-ttl dead
  window), which still applies to local recursion. Rework from
  "probe-primary breaker" to "recurse; on SERVFAIL/timeout for a name,
  forward to ISP." **Spike** the kresd 5.x API for recurse-then-fallback
  (`policy.on_failure`-style). Reuse `dns-isp-fallback.nix` for the ISP
  list from the WAN lease. If no clean API exists, fall back to Unbound-
  style `serve-stale` semantics in kresd (`cache` prefill / serve-stale)
  and accept no ISP fallback — record the choice.

### 2c — Remove phantasma  *(NOT STARTED)*

Bigger than deleting the guest dir — phantasma is a registry **host**, so
the removal ripples:

- Delete `hosts/thebeyond/microvm/guests/phantasma/`.
- `lib/common/data/network.nix`: remove the `phantasma` host (id 10),
  its `dnsHosts` entry (line ~348) and any aliases.
- `hosts/thebeyond/router.nix`: remove the `phantasma` binding, the
  `phantasma → internet` recursive-DNS/NTP egress saddr rules, the
  `interception.extraExcludeAddresses = [phantasma.ipv6]`, and the
  phantasma upstream.
- `hosts/thebeyond/microvm/default.nix` + `default.nix`: drop the guest
  and its persist dirs.
- Sweep the ripples found in this repo:
  `hosts/calvard/.../{langport,messeldam/authelia,tharbad/perses}`,
  `modules/common/fluent-bit.nix`, and the network/test fixtures
  (`tests/lib/{network-registry,network-helpers,network-prefix-length}`,
  `tests/modules/router6-network-zone-egress.nix`). Each references
  phantasma as a host (extraHosts, log routing, dashboards) and needs a
  decision: drop, or repoint.
- thebeyond's chrony already provides the DNSSEC clock (confirmed) — no
  new time-sync dependency.

### 2d — Test migration  *(NOT STARTED)*

- Replace `tests/modules/phantasma-dns-real.nix` with a thebeyond-resolver
  test: recursion works, DNSSEC validates, and the three split-horizon
  zone behaviours from 2a (static NXDOMAIN-unknown, transparent override +
  forward, recursion) hold against a real kresd.
- Retire/relocate `tests/modules/phantasma-dns.nix` and
  `tests/lib/blocky-config.nix` (now covered by Piece 1's feature test).
- Update `router6-dns-fallback.nix` for the fallback rework decided in 2b.

---

## Sequencing & rollback

- **PR-1 = Piece 1.** Restores blocking immediately, leak-free. kresd
  still → phantasma. Rollback = revert the feature commit; back to
  no-blocking. Low risk.
- **PR-2 = Piece 2.** kresd recursive + local-data + phantasma removal.
  Land 2a/2b (kresd self-sufficient, phantasma still present but unused)
  and validate before 2c (removal) so there's a safe intermediate. Keep
  the pre-removal commit hash in the PR for one-command revert.

Deploy note (both pieces): the front `:53` binding changes hands
(kresd→Blocky in P1; backend internals in P2), so each deploy restarts the
client-facing resolver — expect a brief resolution blip. Re-IP/DNS-order
caveats: [[feedback_reip_phantasma_first]] no longer applies once phantasma
is gone, but until then deploy phantasma-affecting changes in the right
order.

## Open items / spikes

1. **Blocky CIDR-keyed empty group** = no blocking (1c) — verify, else use
   a named noblock group.
2. **kresd split-horizon** static/transparent semantics (2a) — spike with
   a real-kresd VM test before writing the generator.
3. **kresd recurse-then-ISP-fallback** API (2b) — spike; decide fallback
   vs. serve-stale-only.
4. **phantasma ripple decisions** (2c) — for each non-DNS consumer
   (perses, fluent-bit, authelia, langport extraHosts), drop or repoint.
