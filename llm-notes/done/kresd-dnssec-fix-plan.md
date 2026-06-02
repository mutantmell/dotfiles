# Fix kresd DNSSEC validation on thebeyond

**Status:** Shipped 2026-05. Both fixes landed:

- Primary path switched to `policy.STUB` via `router6.dns.upstreamPolicy = "stub"` (`hosts/thebeyond/router.nix:584`).
- Root KSK pinned via `pkgs.dns-root-data` in read-only mode (`modules/router6/dns.nix:181`).
- `router6.dns.enableDNSSEC = true` on thebeyond (`hosts/thebeyond/router.nix:578`).
- DNSSEC tests at `tests/modules/router6-dnssec.nix`.

Recommended follow-up (still open): switch fallback target from
ISP-from-lease to a DNSSEC-aware public resolver (Quad9/Cloudflare).
Without that, fallback during signing-aware-only-upstream outages still
SERVFAILs signed queries.

## Why now

`router6.dns.enableDNSSEC = false` is currently set on thebeyond
(`hosts/thebeyond/router.nix`) with a comment documenting that turning
it on produces SERVFAIL across every query and that the dead state does
not heal on restart. The existing rationale ("validation happens upstream
at phantasma's Unbound") was acceptable while kresd was a pure
forwarder, but it stopped being acceptable once the ISP-fallback path
landed (`modules/router6/dns-isp-fallback.nix`):

- Primary path (Unbound on phantasma): Unbound validates, kresd trusts.
- **Fallback path (ISP DNS): nothing validates.** ISP resolvers often
  strip DNSSEC records, and even when they don't, kresd has its
  validator turned off, so the AD bit (if present) is not enforced.

The fallback path is exactly when we most want DNSSEC: we're already in
a degraded state with the local recursive resolver unreachable, and
falling back to an upstream we don't fully trust. Running unvalidated
queries through an ISP resolver during an outage is the worst possible
moment to drop DNSSEC.

Goal: turn `enableDNSSEC = true` back on at the router, with kresd's
trust anchor stable across reboots and across the primary→fallback
transition.

## What we know

From `modules/router6/dns.nix:159–165`:

```lua
-- knot-resolver >=5.7: there is a default trust anchor for `.`,
-- and set_insecure refuses to mark a name as NTA when it already
-- has a TA. Drop the TA first, then mark `.` insecure.
trust_anchors.remove('.')
trust_anchors.set_insecure({ '.' })
```

So when `enableDNSSEC = false` we explicitly tear down the default `.`
TA. When `enableDNSSEC = true` we use whatever ships with knot-resolver.

From `router.nix:553–558` (the original failure note):

> taupd refresh fails (rcode 2 against its own validator) and every
> forwarded query then times out into SERVFAIL. Service restart does
> not heal the state.

This points at the trust-anchor refresh path (RFC 5011 / knot-resolver's
`ta_update` module) failing in a way that poisons the resolver: once
the TA state is broken, every subsequent query routes through a
validator that has no usable trust anchor.

`/var/lib/knot-resolver` is persisted via impermanence
(`router.nix:827–830`), so trust-anchor state survives reboots — which
matches the "restart does not heal" observation.

## Plan

Two independent improvements, each correct on its own. Apply both
together — they share the same code path and the same risk surface.

### Fix 1 — Primary path: `policy.FORWARD` → `policy.STUB`

`policy.FORWARD` re-validates the upstream's answers locally. That only
works if the full DNSSEC chain (RRSIGs, DS records, DNSKEYs over the
forwarder hop) survives the trip from Unbound, which is fragile and
also redundant — phantasma's Unbound already validates.

`policy.STUB` is "FORWARD without local DNSSEC validation": kresd
passes the answer through and does _not_ enforce the upstream's AD
bit. The security model on the primary path becomes "trust Unbound
plus a trusted LAN path", not "trust Unbound's AD bit" — kresd
isn't authenticating Unbound's answers at all. That's acceptable
here because:

- brMGMT is a switched/wired bridge inside thebeyond; an attacker on
  that path already owns more than DNS.
- Unbound on phantasma is the authoritative validator and we control
  it end-to-end.

But it does mean: never point STUB at an upstream we don't fully
trust on the network path. The fallback path uses FORWARD precisely
because we don't trust the ISP resolver, and we want kresd to
locally re-validate everything coming back from it.

Concrete change in `modules/router6/dns.nix`:

- `strictFailoverLua`: `local primary = policy.FORWARD(primary_servers)`
  → `local primary = policy.STUB(primary_servers)`.
- Single-primary branch (`hasPrimary && !hasFallback`):
  `policy.add(policy.all(policy.FORWARD({…})))`
  → `policy.add(policy.all(policy.STUB({…})))`.
- Keep `policy.FORWARD(fallback_dns)` on the fallback path.
- The strict-failover probe (`resolve('.', kres.type.SOA, …)`) DOES
  go through the policy layer — internal `resolve()` calls re-enter
  the layer pipeline. The existing dispatcher already handles this
  via the `if probe_in_flight then return primary` guard at the top
  of the `policy.add` callback, so the probe runs against STUB after
  the switch. That's fine for liveness (it just needs a `.` SOA
  rcode), but document that the probe no longer carries local
  validation either.

### Fix 2 — Pin a static root KSK in read-only mode

The current "kresd default TA + auto-refresh" path is the moving part
that breaks. Replace it with a pinned static IANA root anchor:

- Use `pkgs.dns-root-data` (already in nixpkgs) which ships the IANA
  root KSK as `${pkgs.dns-root-data}/root.key` in BIND DNSKEY format —
  exactly what `trust_anchors.add_file` expects.
- In `modules/router6/dns.nix` (gated on `cfg.dns.enableDNSSEC`):
  ```lua
  trust_anchors.remove('.')
  trust_anchors.add_file('${pkgs.dns-root-data}/root.key', true)
  ```
  The second arg (`true`) is the `readonly` flag. In knot-resolver,
  `add_file` always loads `ta_update`; the `readonly` flag is what
  disables RFC 5011 file-writes (sets `managed=false` internally).
  So we get the auto-refresh machinery loaded but unable to mutate
  the on-disk anchor — `ta_update` essentially becomes a no-op for
  this TA. Do NOT call `modules.unload('ta_update')` afterward: any
  subsequent `add_file`/`add` call would re-load it, and the unload
  alone doesn't undo the `start(owner, managed=false)` already issued.
  The `readonly=true` arg is the only knob we need.
- The leading `trust_anchors.remove('.')` is preserved for symmetry
  with the `set_insecure` branch above it. It is not strictly
  necessary — `add_file` warns and replaces an existing TA — but it
  makes the intent explicit and silences the warning.
- Add an assertion in `modules/router6/default.nix` that
  `pkgs.dns-root-data` exists when `cfg.dns.enableDNSSEC` is set.
- Accept that the root KSK rolls roughly once a decade — when it
  does, a nixpkgs bump picks up the new revision automatically.

### Wire-up

Flip `router6.dns.enableDNSSEC = true` on `hosts/thebeyond/router.nix`
and remove the comment-block rationale (preserve the bug history in
the commit message, not in code).

### Test

Add a NixOS VM test under `tests/modules/` alongside the existing
`router6-kresd-config` check, covering:

1. **Cold-boot DNSSEC**: kresd starts, resolves a signed domain
   (e.g. `cloudflare.com`), AD bit set. No SERVFAIL.
2. **Bogus-signed domain**: `dnssec-failed.org` returns SERVFAIL with
   `EDE 6` (DNSSEC bogus) — confirms validation actually runs.
3. **Fallback path validates a signing-aware upstream**: kill the
   primary upstream, force the strict-failover dispatcher to trip,
   query a signed domain through a mock fallback that returns
   RRSIGs (AD still set on the kresd answer) and a bogus domain
   (SERVFAIL). This is the load-bearing test for the whole
   motivation of this plan.
4. **Fallback path FAILS CLOSED when upstream strips DNSSEC**: same
   as #3 but with a mock fallback that strips RRSIGs from its
   answers. Expectation: kresd returns SERVFAIL for any signed
   name. This is intentional — see the out-of-scope note below.
5. **No TA refresh poisoning**: simulate a refresh tick and confirm
   queries keep succeeding. Should be a non-event with `readonly=true`.

Test #4 is a behavioral contract, not a bug: a fallback that strips
DNSSEC becomes useless once we re-enable validation, and we'd
rather see SERVFAIL than silently lose validation. The follow-up
work (out-of-scope below) is choosing a fallback that does honor
the DO bit.

## Acceptance criteria

- `router6.dns.enableDNSSEC = true` on thebeyond, deployed and stable
  for at least one DHCP lease renewal cycle on the WAN.
- `dig +dnssec cloudflare.com @<thebeyond>` returns AD bit set.
- `dig +dnssec dnssec-failed.org @<thebeyond>` returns SERVFAIL with
  the EDE bogus indicator.
- Primary→fallback transition (probe-triggered) does not lose DNSSEC
  validation — same AD/SERVFAIL behavior holds.
- The five VM tests above pass.

## Risks

- **ISP resolver may strip DNSSEC records.** Once we enable
  validation, any signed-name query that fails over to a
  RRSIG-stripping ISP resolver SERVFAILs. Today those queries
  silently get an unsigned answer. This is a correctness improvement
  but a user-visible regression on the fallback path if the ISP is
  DNSSEC-hostile. The follow-up (see Out of scope) is to point the
  fallback at Quad9 or Cloudflare, both of which serve DNSSEC.
- **Cold-boot ordering with the fallback file.** `strictFailoverLua`
  unconditionally `dofile`s `/run/knot-resolver/isp-dns.lua` at
  config-load. `kresd-isp-fallback-render` already runs `Before=`
  kresd, but verify against the new test rig — a missing file at
  kresd start is now harder-failing because the fallback path is
  load-bearing for DNSSEC.

## Out of scope

- Switching the architecture so kresd recurses locally (would make
  Unbound on phantasma redundant — separate decision, not driven by
  this bug).
- Changing the fallback target from ISP-from-lease to a fixed
  DNSSEC-aware public resolver (Quad9 `9.9.9.9` / Cloudflare
  `1.1.1.1`). Strongly recommended as the immediate follow-up to
  this plan — without it, test #4 represents a real degradation
  scenario in production.
- Removing the static fallback file path (`/run/knot-resolver/isp-dns.lua`)
  ordering hazard — covered by `dns-upgrades-plan.md`.

## References

- `hosts/thebeyond/router.nix:550–566` — current `router6.dns` block
  with the DNSSEC-off rationale.
- `modules/router6/dns.nix:159–165` — kresd Lua snippet that disables
  the TA when `enableDNSSEC = false`.
- `modules/router6/dns.nix:29–117` — strict-failover dispatcher (relevant
  for primary/fallback interactions).
- `modules/router6/dns-isp-fallback.nix` — ISP DNS render path.
- knot-resolver `policy.STUB` / `policy.FORWARD` docs:
  https://www.knot-resolver.cz/documentation/stable/modules-policy.html
  — confirms STUB is "FORWARD without DNSSEC validation".
- knot-resolver `trust_anchors.add_file(path, readonly)` —
  `readonly=true` sets `managed=false`, which is what disables
  RFC 5011 on-disk updates without unloading `ta_update`.
- nixpkgs `dns-root-data` — provides `${pkgs.dns-root-data}/root.key`
  in BIND DNSKEY format.
- `llm-notes/wip/dns-upgrades-plan.md` — fallback architecture context.
- `llm-notes/wip/blocky-migration-plan.md` — adjacent upstream-side
  rework that landed the Blocky → Unbound chain on phantasma.
