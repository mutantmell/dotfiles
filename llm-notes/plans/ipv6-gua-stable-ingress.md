# Plan: Stable GUA Addresses via SLAAC Token

## Context

**Prerequisite:** `ipv6-static-ingress-slaac-egress.md` (ULA ingress/egress split)
and confirmed ISP prefix delegation working on thebeyond.

### How all hosts get GUA addresses (already handled)

When prefix delegation is deployed, the router advertises both ULA and GUA
prefixes in Router Advertisements on each LAN VLAN (via `pdSubnetId` +
`DHCPPrefixDelegation` from the WAN PD plan). Once the ULA plan enables
`IPv6AcceptRA = true` on all hosts, every host automatically gets SLAAC
addresses from **both** prefixes:

- **ULA SLAAC**: `fdc6:55f2:0a5e:<vlan>::<random>/64` (privacy, rotating)
- **GUA SLAAC**: `<delegated-prefix>:<vlan>::<random>/64` (privacy, rotating)
- **ULA static**: `fdc6:55f2:0a5e:<vlan>::<hostHex>/64` (stable, from registry)

With `IPv6PrivacyExtensions = "yes"`, outbound connections prefer the temporary
SLAAC addresses (both ULA and GUA). The kernel's RFC 6724 source address
selection prefers GUA over ULA for destinations outside the ULA prefix, so
internet-bound traffic naturally uses the GUA SLAAC address. No NAT66 needed —
the router forwards with the original GUA source.

This means **every host on a PD-enabled VLAN gets working IPv6 internet access
via GUA SLAAC** with no additional configuration beyond the ULA plan. VM hosts
(remiferia, calvard, erebonia) that manage their own NixOS updates reach the
WAN with rotating GUA privacy addresses — no NAT involved.

### What this plan adds

The above gives every host a _rotating_ GUA for egress but no _stable_ GUA. This
plan adds a stable, predictable GUA address to **every registered host** using
systemd-networkd's SLAAC `Token` mechanism. The Token ensures each host gets
`<delegated-prefix>::a0<hostHex>` — an offset host ID that avoids the scannable
low range while remaining derivable from the network registry.

Benefits of applying this to all hosts (not just external-facing ones):

- **Consistent addressing** — every host's GUA is predictable from its registry
  entry, same pattern as ULA. No need to remember which hosts have stable GUA.
- **Operational simplicity** — troubleshooting, logging, and monitoring can
  correlate GUA traffic to hosts by the stable host ID suffix.
- **Future-proofing** — if any host later needs inbound GUA access (monitoring
  hooks, direct SSH, peer-to-peer), the stable address already exists.
- **No privacy cost** — `IPv6PrivacyExtensions = "yes"` still generates and
  prefers temporary addresses for egress. The stable GUA is an additional address,
  not a replacement for the privacy address.
- **Minimal extra work** — one line per host (`Token = "static:::a0XX"`), and the
  host IDs already exist in the network registry.

### Design decisions

**SLAAC Token, not DHCPv6 reservations.**

The obvious approach for stable GUA would be DHCPv6 reservations (parallel to
DHCPv4). But Kea DHCPv6 reservations require a full IPv6 address in
`ip-addresses`, and the ISP-delegated prefix is dynamic — it can change on
renewal. Kea doesn't support "assign the same host-part from whatever prefix
is currently delegated."

systemd-networkd's SLAAC `Token` mechanism solves this cleanly. When a host
receives an RA with a prefix, `Token = "static:::XX"` tells it to use `::XX`
as the interface identifier instead of a random value. The host gets
`<whatever-prefix>::XX` regardless of what the prefix is. This works with any
delegated prefix, requires no router-side configuration per host, and the host
ID comes from the centralized network registry (unique per VLAN).

The tradeoff: the host, not the router, chooses its address. If two hosts pick
the same Token on the same subnet, there's a conflict. Since Tokens come from
the network registry (unique host IDs per VLAN), this won't happen.

**GUA host IDs use a sparse offset, not the low ULA IDs.**

The ULA registry assigns low host IDs (`::1` through `::3d`). These are fine for
ULA (not routable from the internet) but problematic for GUA. RFC 7707 (Network
Reconnaissance in IPv6) documents that attackers prioritize scanning low addresses
(`::1` through `::ff`) because that's where administrators commonly place
infrastructure. Scanning tools like `scan6` and `alive6` target this range by
default.

To avoid this, GUA Tokens use an offset: `::a0XX` where `XX` is the hex host ID
from the registry. For example, remiferia (hostId=20, hex=0x14) gets Token
`static:::a014` instead of `static:::14`. This moves all hosts out of the
commonly-scanned low range while keeping the scheme deterministic and derivable
from the registry.

The offset `a0` is arbitrary — any value that places hosts outside `::0-::ff`
works. `a0` was chosen because:

- Well outside the `::1-::ff` range scanners target
- Well outside the `::1000-::1fff` DHCPv6 dynamic pool (if ever used)
- Short enough to be readable in logs
- The resulting addresses (`::a001` through `::a0ff`) are still in a sparse
  region of the /64

**Apply the same offset to ULA addresses for consistency.**

ULA addresses don't strictly need scan resistance (not internet-routable), but
using the same `::a0XX` scheme for both ULA and GUA keeps addressing uniform —
one pattern to remember, and you can always derive ULA from GUA or vice versa by
swapping the prefix.

The transition is low-risk because:

- IPv4 addresses provide fallback connectivity during the change
- Most ULA references go through the network registry (`host.cidr6`, `host.ipv6`)
  and update automatically when `mkHost` is changed
- DNS and firewall rules are auto-generated from the registry
- Only two files have hardcoded ULA host addresses that need manual updates:
  `hosts/calvard/incus/guests/edith/default.nix` and
  `hosts/erebonia/incus/guests/trista/default.nix` (these should be switched to
  use the registry helper anyway)
- WireGuard peer `allowedIPs` in `hosts/thebeyond/router.nix` use WG-specific
  prefixes and should follow the same convention

**No mode changes needed.**

The Token mechanism works with SLAAC (`dhcp6.mode = "slaac"`). No need to switch
VLANs to `stateful` mode. The router just advertises the delegated prefix in RAs
(already configured by the PD plan), and hosts choose their interface identifier
via Token. This avoids adding Kea DHCPv6 complexity.

**DNS for GUA addresses.**

External DNS (public AAAA records for internet-facing services) must point to
stable GUA addresses. The prefix is dynamic, so these can't be set at build time.
Options:

1. **Dynamic DNS update script** — monitor the delegated prefix and update
   external DNS when it changes. Most ISPs rarely change the prefix.
2. **Hostname-based reverse proxy** — langport handles all external traffic;
   only langport's GUA needs a public AAAA record. Reduces the problem to one
   host.

Defer the choice until deployment — depends on ISP prefix stability.

Internal DNS (kresd/unbound) already has ULA AAAA records. Internal services
should use ULA for host-to-host communication — GUA is for internet-facing
traffic.

## Changes

### 1. Update network registry to use offset host IDs

**File:** `lib/common/data/network.nix`

Change `mkHost` to generate `::a0XX` addresses instead of `::XX`:

```nix
# Before:
ipv6 = "${ulaPrefix}:${vlanHex vlanId}::${hostHex hostId}";
cidr6 = "${ulaPrefix}:${vlanHex vlanId}::${hostHex hostId}/64";

# After:
ipv6 = "${ulaPrefix}:${vlanHex vlanId}::a0${hostHex hostId}";
cidr6 = "${ulaPrefix}:${vlanHex vlanId}::a0${hostHex hostId}/64";
```

This propagates automatically to all DNS records, firewall rules, `/etc/hosts`,
and host configs that use `host.cidr6`/`host.ipv6`.

**Manual fixups:**

- `hosts/calvard/incus/guests/edith/default.nix` — hardcoded ULA → switch to
  registry (`host.cidr6`) or update the address
- `hosts/erebonia/incus/guests/trista/default.nix` — same
- `hosts/thebeyond/router.nix` — WireGuard `allowedIPs` on WG-specific prefixes

**Gateway addresses stay at `::1`.** The `gateway6` in the registry is derived
separately (`"${ulaPrefix}:${vlanHex net.vlanId}::1"`) and should not change —
the router is always `::1` on each subnet.

### 2. Configure all hosts to use static Token for GUA

**Files:** Every registered host's systemd-networkd config.

For each host, add the SLAAC Token to their network config. The Token value
matches the offset host ID from the registry:

```nix
# Example for langport (hostId = 41, hex = 0x29, DMZ VLAN):
ipv6AcceptRAConfig = {
  Token = "static:::a029";
};
```

The host will get:

- ULA static: `fdc6:55f2:0a5e:64::a029/64` (from registry)
- GUA stable: `<delegated-prefix>:64::a029/64` (SLAAC with Token — same suffix)
- GUA temporary: `<delegated-prefix>:64::<random>/64` (SLAAC privacy, for egress)
- ULA temporary: `fdc6:55f2:0a5e:64::<random>/64` (SLAAC privacy)

ULA and GUA stable addresses share the same `::a029` suffix. The temporary
addresses rotate for egress privacy.

Note: the Token also generates a SLAAC address on the ULA prefix at
`fdc6:55f2:0a5e:64::a029/64`. Since step 1 updates the registry to use the
same `::a0XX` scheme, this SLAAC-derived address matches the static address —
they're the same. No duplicate/conflicting addresses.

Full host list with Token values (derived from network registry with `a0` offset):

| Host        | Zone       | hostId | hex | Token           | GUA suffix |
| ----------- | ---------- | ------ | --- | --------------- | ---------- |
| thebeyond   | management | 1      | 1   | `static:::a001` | `::a001`   |
| phantasma   | management | 2      | 2   | `static:::a002` | `::a002`   |
| tharbad     | management | 5      | 5   | `static:::a005` | `::a005`   |
| messeldam   | management | 6      | 6   | `static:::a006` | `::a006`   |
| basel       | management | 7      | 7   | `static:::a007` | `::a007`   |
| remiferia   | management | 20     | 14  | `static:::a014` | `::a014`   |
| calvard     | management | 30     | 1e  | `static:::a01e` | `::a01e`   |
| erebonia    | management | 31     | 1f  | `static:::a01f` | `::a01f`   |
| azoth       | trusted    | 50     | 32  | `static:::a032` | `::a032`   |
| edith       | lab        | 42     | 2a  | `static:::a02a` | `::a02a`   |
| glorious    | adu        | 20     | 14  | `static:::a014` | `::a014`   |
| arseille    | network    | 12     | c   | `static:::a00c` | `::a00c`   |
| merkabah    | network    | 20     | 14  | `static:::a014` | `::a014`   |
| derfflinger | network    | 21     | 15  | `static:::a015` | `::a015`   |
| pantagruel  | network    | 22     | 16  | `static:::a016` | `::a016`   |
| bobcat      | network    | 23     | 17  | `static:::a017` | `::a017`   |
| lusitania   | network    | 24     | 18  | `static:::a018` | `::a018`   |
| ardent      | dmz        | 31     | 1f  | `static:::a01f` | `::a01f`   |
| trista      | dmz        | 51     | 33  | `static:::a033` | `::a033`   |
| langport    | dmz        | 41     | 29  | `static:::a029` | `::a029`   |
| oracion     | dmz        | 52     | 34  | `static:::a034` | `::a034`   |
| creil       | dmz        | 53     | 35  | `static:::a035` | `::a035`   |
| monrain     | dmz        | 32     | 20  | `static:::a020` | `::a020`   |
| saint-arkh  | dmz        | 61     | 3d  | `static:::a03d` | `::a03d`   |

Note: Token values are unique within each VLAN (same guarantee as the network
registry's host IDs). Hosts on different VLANs can have the same Token since
they're on different /64 subnets.

### 3. Verify router6 PD configuration (no changes needed)

The WAN IPv6 PD plan (already implemented) configures:

- `pdSubnetId` on LAN interfaces → each VLAN gets a /64 from the delegated pool
- `Token = "::1"` on the router → router gets `<prefix>::1` on each subnet
- RA advertises the delegated prefix alongside ULA

Hosts that accept RAs (enabled by the ULA plan) automatically get SLAAC
addresses from both prefixes. The Token mechanism ensures the GUA SLAAC address
uses a predictable host ID.

The router's gateway Token stays at `::1` — it's the default gateway and
discoverable via RA regardless, so the scan-resistance offset doesn't apply.

### 4. Integration test

**New file:** `tests/modules/router6-ipv6-gua-token.nix`

Extend the existing PD test topology:

- ISP node with PD pool (reuse pattern from `router6-wan-ipv6-pd.nix`)
- Router with PD enabled, one LAN VLAN with `pdSubnetId`
- Client with static ULA + `IPv6AcceptRA = true` + `Token = "static:::a042"` +
  `IPv6PrivacyExtensions = "yes"`

Verify:

1. Client gets ULA address (static, from config)
2. Client gets GUA address with the offset Token host ID (`<prefix>::a042`)
3. Client gets at least one GUA temporary address (privacy)
4. Client can ping ISP via GUA (end-to-end forwarding)
5. Client can ping router via ULA (internal connectivity)
6. The Token-derived GUA is stable (matches expected host ID)

Wire into `tests/router6.nix`.

## Files to modify

### Registry:

1. `lib/common/data/network.nix` — Change `mkHost` to generate `::a0XX` addresses

### Host configs:

2. All registered hosts: add `ipv6AcceptRAConfig.Token` to systemd-networkd
   (same files as the ULA plan — can be done in the same change)
3. `hosts/calvard/incus/guests/edith/default.nix` — fix hardcoded ULA
4. `hosts/erebonia/incus/guests/trista/default.nix` — fix hardcoded ULA
5. `hosts/thebeyond/router.nix` — update WireGuard `allowedIPs`

### Tests:

6. `tests/modules/router6-ipv6-gua-token.nix` (create)
7. `tests/router6.nix` (add entry)
8. Existing tests that reference ULA host addresses may need updates (most use
   gateway `::1` which doesn't change, but `tests/lib/network-helpers.nix`
   references specific host addresses from the registry and will need updating)

## Dependencies

- ISP must provide IPv6 prefix delegation (unconfirmed)
- thebeyond must be deployed with PD enabled
- `ipv6-static-ingress-slaac-egress.md` should be deployed first (hosts accepting
  RAs is a prerequisite for Token-based GUA addressing)

## Verification

```bash
# Run the new GUA token test
nix build .#checks.x86_64-linux.router6-ipv6-gua-token --print-build-logs

# Regression: PD test still passes
nix build .#checks.x86_64-linux.router6-wan-ipv6-pd --print-build-logs

# All checks
./scripts/run-checks.sh -j1
```
