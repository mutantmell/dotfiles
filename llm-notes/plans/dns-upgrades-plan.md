# DNS Architecture Upgrades — Plan

## Motivation

Recent thebeyond deploy surfaced a ~1-minute window where new external DNS
names failed to resolve while cached entries (browser + OS) kept working —
classic shape of Unbound's `infra-host-ttl = 60s` dead-state firing for one
or more authoritative servers. Symptom hit specific services (Hulu, HBO
Max) while others (YouTube) kept working, ruling out a WAN-wide outage.

This isn't an Unbound defect — it's the intrinsic exposure of any
recursive resolver to transient upstream issues. The OpenWrt setup never
showed this because it forwarded to ISP resolvers instead of recursing
locally. The previous kresd config had a Lua fallback policy for exactly
this scenario; it was removed under the (now-disproved) assumption that
local recursion would be reliable enough.

Three improvements come out of this:

1. **Restore the kresd fallback** so recursion stalls degrade to public
   DNS instead of SERVFAIL.
2. **Move authoritative homelab zone data from Unbound → kresd** so
   internal name resolution survives phantasma restarts.
3. **Per-VLAN ad-block exemption on GUEST (tag 30)** so a household
   member's work needs aren't blocked by the homelab's blocklist.

Each phase is independently useful. Phase 1 is the urgent fix. Phases 2
and 3 are architectural improvements that the same kresd Lua config
naturally accommodates.

## Current vs. target architecture

```
Current:
  client → DNAT → thebeyond:kresd (cache, forward-only)
                       ↓
                phantasma:Blocky (blocklist)
                       ↓
                phantasma:Unbound (recursive + authoritative .internal)
                       ↓
                       roots

Target:
  client → DNAT → thebeyond:kresd (cache + authoritative .internal +
                                   source-IP routing + upstream fallback)
                       ↓ (non-internal queries)
              ┌────────┴────────┐
              ↓ (GUEST tag 30)  ↓ (other zones)
        phantasma:Unbound  phantasma:Blocky (blocklist)
        (recursive only)         ↓
              ↓                  phantasma:Unbound (recursive)
              roots                    ↓
                                       roots

  Fallback (any path): kresd retries against public DNS on
  SERVFAIL / timeout from primary forward chain.
```

Each layer has one job:

- **kresd-on-thebeyond**: authoritative for homelab zones, client-facing
  resolver, source-based policy, upstream fallback.
- **Blocky**: blocklist enforcement only.
- **Unbound**: recursive resolution only.

## Phase 1 — kresd upstream fallback **(DEPLOYED)**

> **Status:** Deployed and validated. Shipped as a strict-failover
> dispatcher in `modules/router6/dns.nix` (Lua-driven probe + breaker
> rather than the original `policy.on_failure` sketch — see comment
> block at lines 28–34 for why). Lease-file renderer in
> `modules/router6/dns-isp-fallback.nix`. Wired up on the router via
> `router6.dns.fallbackFromLease = "enp4s0"` in
> `hosts/thebeyond/router.nix`. Three real fallback events between
> May 28–31 2026 all mapped 1:1 to planned phantasma reboots —
> breaker behaves correctly (see
> [[project-kresd-fallback-handles-phantasma-reboots]]). Original
> design sketch below is preserved for context; the as-shipped
> implementation is what's in the code.

**Goal:** when forwarding to phantasma stalls (SERVFAIL or timeout),
retry against a public resolver so clients don't see a 60s dead window.

**Scope:** `modules/router6/dns.nix` only.

**Approach:** extend the `extraConfig` Lua with a chained policy. kresd's
policy engine evaluates rules in order; a `policy.FORWARD` that fails
falls through to the next matching rule. We add a secondary FORWARD that
matches the same name range (`.`) and targets public DNS. With kresd 5.x,
the cleanest way is to use the `policy.STUB` / `policy.FORWARD` chain
with a custom action that catches upstream failures.

**Concrete sketch:**

```nix
extraConfig = ''
  modules.load('policy')

  -- Primary: forward to phantasma (Blocky → Unbound)
  policy.add(policy.suffix_common(
    policy.FORWARD({${primaryUpstreams}}),
    todname('.')
  ))

  -- Fallback: if primary returns SERVFAIL or times out, public DNS
  -- (configurable via cfg.dns.fallbackUpstream)
  ${optionalString (cfg.dns.fallbackUpstream != []) ''
    policy.add(policy.on_failure(
      policy.FORWARD({${fallbackUpstreams}})
    ))
  ''}

  ${... existing trust-anchor + cache.size ...}
''
```

The `policy.on_failure` (or equivalent custom action — needs verification
against kresd 5.x API) is the moving part. If kresd doesn't expose a
ready-made hook, the fallback is a small Lua callback that re-resolves
through the fallback chain on receipt of a SERVFAIL/timed-out answer.

**Fallback target: ISP DNS from WAN DHCP lease (dynamic).**

The WAN DHCP lease on `enp4s0` already contains ISP-provided DNS
servers — systemd-networkd records them in
`/run/systemd/netif/leases/<ifindex>` as `DNS=` lines. We render them
into a kresd-readable file at boot and re-render on lease change.

Implementation shape (one new sub-module —
`modules/router6/dns-isp-fallback.nix` — feeding into
`modules/router6/dns.nix`):

1. **Oneshot renderer** — systemd service ordered after the
   `systemd-networkd-wait-online` instance for the WAN interface,
   before `kresd@*.service`. It reads
   `/run/systemd/netif/leases/$(cat /sys/class/net/<WAN_IF>/ifindex)`,
   extracts the `DNS=` line, and writes
   `/run/kresd/isp-dns.lua` of the form `return { '1.2.3.4', '5.6.7.8' }`.
   If the lease file is missing or has no DNS, write a static safe
   default (Quad9: `9.9.9.9`, `149.112.112.112`) so kresd always has
   _something_ to fall back to.

2. **Path unit watching the lease file** — on lease change (DHCP
   renewal that updates DNS, ISP reconfig, etc.), re-trigger the
   renderer and reload kresd. systemd's `PathChanged=` against
   `/run/systemd/netif/leases/<ifindex>` is the right primitive.

3. **kresd consumes via `dofile`** in `extraConfig`:

```lua
local fallback_dns = dofile('/run/kresd/isp-dns.lua')
policy.add(policy.on_failure(policy.FORWARD(fallback_dns)))
```

At kresd start, the file is guaranteed present (oneshot ordered
before kresd). On lease change, kresd reload re-evaluates the
config and picks up the new list.

**Module option:**

```nix
fallbackFromLease = mkOption {
  type = nullOr str;
  default = null;
  example = "enp4s0";
  description = ''
    WAN interface whose DHCP lease provides fallback DNS servers.
    When set, the lease's DNS= field is rendered to a file consumed
    by kresd's fallback policy. Falls back to a hardcoded safe default
    (Quad9) if the lease has no DNS info or hasn't been acquired yet.
  '';
};

fallbackUpstream = mkOption {
  type = listOf str;
  default = ["9.9.9.9" "149.112.112.112"];
  description = ''
    Static fallback resolvers used when fallbackFromLease is null or
    the lease hasn't yielded DNS yet. Defaults to Quad9.
  '';
};
```

`hosts/thebeyond/router.nix`:

```nix
router6.dns.fallbackFromLease = "enp4s0";
```

**Edge case** — IPv6 RDNSS via SLAAC instead of DHCPv6. If the ISP
provides IPv6 DNS via Router Advertisement RDNSS, those land in a
different networkd state file (or get consumed by resolved if
running). For Phase 1 we accept that fallback may be IPv4-only;
revisit if needed.

**Edge case** — the renderer runs as root for /run/kresd/ write
access. The output file is world-readable (no secrets — just public
ISP resolver IPs). kresd runs as its own user; ensure /run/kresd is
owned/accessible (set `RuntimeDirectory=kresd` on the renderer
service or use the existing kresd runtime dir).

**Verification:**

- Existing `router6-kresd-config` test should pass with default
  (no fallback) and grow assertions for fallback Lua presence.
- New VM test: kill phantasma's Blocky mid-query, confirm queries still
  resolve via fallback path.

## Phase 2 — Move authoritative zone data to kresd

**Goal:** homelab name resolution (`*.internal`,
`*.internal.mutantmell.net`, `*.mutantmell.net` split-horizon overrides)
stays available when phantasma is down. Conceptually align the layering:
"kresd is the homelab's authoritative DNS provider" becomes true.

### Step 2a — Helper: `mkKresdLocalData`

In `lib/common/data/network.nix`, add a sibling to `mkUnboundLocalData`
that emits kresd-flavored local data. kresd represents local zones via
the `policy` module — typically a `hints` file or
`policy.LOCAL_DATA` / `policy.ANSWER` rules.

Expected output shape (Lua text to splice into `extraConfig`):

```lua
-- Generated by mkKresdLocalData
local internal_zones = {
  ['thebeyond.internal.'] = { type = 'A', rdata = '10.91.10.1' },
  ['thebeyond.internal.mutantmell.net.'] = { type = 'A', rdata = '10.91.10.1' },
  ['1.10.91.10.in-addr.arpa.'] = { type = 'PTR', rdata = 'thebeyond.internal.' },
  -- ... one row per host × suffix × address-family
}
-- Wire as authoritative LOCAL_DATA via policy.ANSWER or hints.set
```

The exact wiring API needs verification against kresd 5.x — options
include `policy.add(policy.suffix(policy.ANSWER({...}), ...))` or the
`hints` module configured with explicit zone authority. Whichever the
final API, the helper hides it behind a typed Nix interface mirroring
`mkUnboundLocalData`.

**Aliases** (currently consumed via `mkUnboundAliasData`) — add a parallel
`mkKresdAliasData`.

**Reverse PTR** — Unbound's current config doesn't appear to emit PTRs
explicitly; if we want PTRs as part of the move, add them to the helper
output now. Otherwise hold reverse mappings for a follow-up.

### Step 2b — Wire helpers into thebeyond's kresd

In `modules/router6/dns.nix` (or a new `router6/authoritative.nix`
sub-module), add option:

```nix
authoritativeZones = mkOption {
  type = listOf str;
  default = [];
  description = "Local zones for which kresd answers authoritatively.";
};

authoritativeRecords = mkOption {
  type = listOf attrs;
  default = [];
  description = "Authoritative records (typically generated via net.mkKresdLocalData).";
};
```

`hosts/thebeyond/router.nix` populates these from the network registry
(same `registeredHosts` list currently in
`phantasma/modules/dns.nix:110-136`).

### Step 2c — Strip authoritative config from phantasma's Unbound

In `hosts/thebeyond/microvm/guests/phantasma/modules/dns.nix`:

- Remove the `local-zone` block (lines 104–108).
- Remove the `local-data` block (lines 109–142).
- Unbound becomes pure recursive resolver.

### Step 2d — Address Blocky's internal-data needs

**User's observation: external clients route via kresd-on-thebeyond,
which now answers `.internal` authoritatively _before_ the query reaches
Blocky. So Blocky doesn't need internal data for external clients.**
Correct.

The only queries hitting Blocky for internal names are those
_originating on phantasma itself_ (libc resolver → 127.0.0.1 → Blocky).
Today's `conditional.mapping` in `phantasma/modules/dns.nix:41-48`
exists to handle exactly that case (Blocky NXDOMAINs RFC 6761 special-use
names without an explicit conditional upstream — see
[[project_blocky_special_use_internal]]).

**Decision: option (a) — repoint phantasma's libc resolver to
thebeyond's kresd.**

Change `DNS = ["127.0.0.1"]` in `phantasma/default.nix:51` to
`DNS = ["${zone.gateway4}"]`. Phantasma becomes a normal DNS client:
kresd answers `.internal` locally, forwards everything else to
phantasma's own Blocky → Unbound. One extra microVM-host hop for
phantasma's external queries (negligible — loopback-class latency on
the same physical host).

Side benefit: phantasma's own queries inherit Phase 1's fallback
automatically with no extra config, and Blocky's `conditional.mapping`
block at `phantasma/modules/dns.nix:41-48` can be deleted entirely
(kresd-on-thebeyond is now the authority — Blocky no longer needs to
know `.internal` exists).

Bootstrap concern: phantasma's libc now depends on thebeyond's kresd
being up _before_ phantasma's services start. In practice phantasma
boots after thebeyond (it's a microVM running on it), so the
dependency is already satisfied by topology. If a unit on phantasma
makes a DNS query before networking is up — unlikely, but worth a
spot-check — it'd fail just as it would today against local 127.0.0.1.

### Step 2e — Test migration

Update `tests/modules/phantasma-dns.nix` and `phantasma-dns-real.nix`:

- Assertions for `.internal` lookups should expect kresd-on-thebeyond
  as the answering server (or just check answer correctness, not source).
- Add new assertion: phantasma stopped → `.internal` queries from
  clients still resolve.

Also update `tests/lib/blocky-config.nix` if it asserts the conditional
mapping contents.

## Phase 3 — Per-VLAN bypass for GUEST (tag 30)

**Goal:** GUEST VLAN (`10.91.30.0/24` + matching IPv6 ULA) bypasses the
Blocky blocklist. ADU/IOT/GAME (tags 31/40/41 — same `untrusted` zone
but different subnets) remain blocked.

### Step 3a — Expose Unbound directly on phantasma

**Decision: expose Unbound on the brMGMT address** (no second Blocky —
NixOS doesn't compose multiple instances of `services.blocky` cleanly).

In `phantasma/modules/dns.nix`, extend Unbound's server config:

```nix
server = {
  interface = [
    "127.0.0.1"
    host.ipv4   # brMGMT IPv4 — reachable from thebeyond
    host.ipv6   # brMGMT IPv6
  ];
  port = 5335;
  access-control = [
    "127.0.0.0/8 allow"
    "::1 allow"
    "${zone.gateway4} allow"  # thebeyond (kresd) only
    "${zone.gateway6} allow"
    "0.0.0.0/0 refuse"
    "::/0 refuse"
  ];
  # ... rest unchanged
};
```

Source-restrict via `access-control` rather than firewall — defense in
depth, and Unbound's ACLs are well-tested for this exact use case.
firewall still adds an inputRule for tcp/udp 5335 on the `network` zone
scoped to thebeyond.

### Step 3b — Source-IP routing in kresd

Extend the kresd Lua to dispatch by source CIDR:

```lua
-- GUEST VLAN bypass: queries from 10.91.30.0/24 go to no-block Unbound
policy.add(policy.suffix_common(
  policy.FORWARD({'phantasma_ip:5335'}),  -- no-block (Unbound direct)
  todname('.'),
  view.addr('10.91.30.0/24')
))
-- Same rule for IPv6 GUEST ULA
policy.add(policy.suffix_common(
  policy.FORWARD({'[phantasma_v6]:5335'}),
  todname('.'),
  view.addr('fdc6:55f2:0a5e:001e::/64')   -- 0x1e = 30
))

-- Default: forward to Blocky (blocklist + recursion)
policy.add(policy.all(policy.FORWARD({'phantasma_ip:53'})))

-- Fallback (Phase 1) — applies to all paths
...
```

`view` module needs `modules.load('view')` at the top.

### Step 3c — Module surface

In `modules/router6/dns.nix`, add option to express per-CIDR forward
overrides without forcing users to write Lua:

```nix
sourceRoutes = mkOption {
  type = listOf (submodule {
    options = {
      cidr = mkOption { type = str; };
      upstream = mkOption { type = listOf str; };
    };
  });
  default = [];
  description = "Forward queries from matching source CIDRs to a
                 specific upstream, bypassing the default chain.";
};
```

`hosts/thebeyond/router.nix` populates from the network registry:

```nix
router6.dns.sourceRoutes = [
  {
    cidr = net.networks.untrusted.subnet4;
    upstream = ["${phantasma.ipv4}:5335"];
  }
  {
    cidr = net.networks.untrusted.subnet6;
    upstream = ["[${phantasma.ipv6}]:5335"];
  }
];
```

### Step 3d — Firewall + access control

- phantasma's UDP/TCP 5335 must be reachable from thebeyond. Either
  bind Unbound to phantasma's external IP (with `access-control`
  allowing thebeyond) or bind to 0.0.0.0:5335 with tighter
  access-control. The latter is simpler; the former more defense-in-
  depth.
- The `network` zone's `inputRules` already allow DNS on 53; add 5335
  scoped to thebeyond's source IP.

### Step 3e — Verification

- New VM test: client in untrusted/30 subnet queries an
  ads-list-blocked domain → answer is the real address (not blocked).
- Existing client in adu/31 subnet queries same domain → still NXDOMAIN
  (blocked). Confirms only GUEST bypasses.
- Stretch: confirm Blocky's metrics show GUEST queries don't pass
  through it (the no-block path skips Blocky entirely).

## Sequencing & rollback

**Two PRs:**

1. **PR-1 (Phase 1)** — kresd ISP-lease fallback. Independent of
   architecture changes, fixes the immediate complaint. Lands first.
2. **PR-2 (Phases 2 + 3 together)** — authoritative data migration and
   GUEST per-VLAN bypass land in a single PR. They touch the same
   kresd `extraConfig` and would interact awkwardly if split (source
   routing references authoritative-handling, removing
   Blocky's conditional mapping references kresd holding the data).

**Rollback per PR:**

- **PR-1**: revert `dns.nix` extraConfig change + the new
  `dns-isp-fallback.nix` module; no data migration. Behavior returns
  to "SERVFAIL on recursion stall," same as today.
- **PR-2**: revert phantasma dns.nix, thebeyond authoritative config,
  and kresd source-routing block in parallel. They go in/out together
  — there is no intermediate state where neither side has the
  authoritative data. Keep the pre-migration commit hash documented in
  the PR description so rollback is a single `git revert`.

## Decisions recap

| Question                        | Decision                                                                                   |
| ------------------------------- | ------------------------------------------------------------------------------------------ |
| Phase 1 fallback target         | ISP DNS from WAN DHCP lease, with static Quad9 default if lease lacks DNS                  |
| Phase 3 no-block endpoint       | Expose Unbound directly on brMGMT (NixOS doesn't multi-instance `services.blocky` cleanly) |
| Phase 2 phantasma libc resolver | Option (a) — repoint at thebeyond's kresd                                                  |
| Phase 2 & 3 sequencing          | Combined into a single PR (PR-2)                                                           |

## Notes / cross-references

- See [[project_blocky_special_use_internal]] for why Blocky's
  `conditional.mapping` exists today.
- See [[feedback_blocky_denylists_pinned]] — denylist source path doesn't
  change in any phase.
- `tests/modules/phantasma-dns.nix` and `phantasma-dns-real.nix` are
  the primary tests to update in Phase 2.
- The existing `blocky-migration-plan.md` in this directory documents
  the most recent prior DNS work; this plan is the natural follow-up.
