# Plan: IPv6 Static Ingress + SLAAC Egress Addressing

## Context

Internal hosts currently use static ULA IPv6 addresses from the network registry
(`fdc6:55f2:0a5e:<vlanHex>::<hostHex>/64`) configured directly in systemd-networkd
with `IPv6AcceptRA = false`. This is stable but means hosts have exactly one IPv6
address — the same address is used for both inbound connections (services listening)
and outbound connections (fetching updates, etc.).

IPv6 best practice (RFC 8981, NIST SP 800-119) recommends separating these concerns:

- **Ingress (stable):** Services bind to a known, predictable address. DNS AAAA records,
  firewall rules, monitoring, and ACLs reference this address.
- **Egress (privacy):** Outbound connections use rotating SLAAC temporary addresses
  (RFC 8981 privacy extensions) so the host can't be tracked by source address.

The hosts already have the stable half (static ULA). They just need SLAAC privacy
addresses for egress. This is a small configuration change per host — no module
changes required.

### Design decisions

**Keep static ULA for ingress, add SLAAC for egress.**

The simplest approach: hosts keep their static ULA address (already configured,
already in DNS, already in firewall rules) and additionally accept Router
Advertisements to get SLAAC temporary addresses for outbound connections. No
DHCPv6 reservations needed — the static address already provides what reservations
would provide, without adding a dependency on Kea being up.

This preserves resilience: if the router goes down, hosts keep both their static
IPv4 and static IPv6 addresses. Hosts on the same subnet can still communicate
over both protocols. SLAAC temporary addresses will eventually expire (governed by
RA lifetime), but the stable static address persists indefinitely.

**Why not DHCPv6 reservations instead of static config?**

DHCPv6 reservations would move the stable address from host config to the router,
making the router the single source of truth. This has appeal but adds complexity
and makes IPv6 dependent on Kea being up. For ULA addresses (which are derived
deterministically from the network registry), there's no benefit — the registry
is already the source of truth, and hosts consume it at build time via
`host.cidr6`.

DHCPv6 reservations _would_ be valuable for **GUA addresses from prefix
delegation** — the ISP-delegated prefix isn't known at build time, so it can't be
statically configured. That's a separate future concern (see "Follow-up" section).

**Why not RFC 7217 stable-privacy addresses?**

RFC 7217 addresses are deterministic per-network but derived from a secret key +
interface ID, so they're not predictable from the network registry. We need
addresses that the infrastructure knows in advance (for DNS, firewall rules, etc.).

**RA trust model:**

Enabling `IPv6AcceptRA = true` opens hosts to rogue RA attacks (a compromised host
on the same VLAN could advertise a malicious prefix/gateway). This is mitigated by:

- VLAN isolation: each VLAN is a separate broadcast domain, so only devices on the
  same VLAN can send RAs. The router is the only device sending RAs.
- The router6 module's zone-based firewall already restricts inter-VLAN traffic.
- For higher-security environments, RA Guard (IEEE 802.1Xbv) can be enabled on
  managed switches. Not implemented here (home network), but the architecture
  supports adding it later.

## Changes

### 1. Enable RA acceptance on hosts

**Files:** Each host's systemd-networkd config (see file list below).

Hosts currently set `IPv6AcceptRA = false`. Change to `true` so they receive
Router Advertisements and generate SLAAC addresses (including temporary/privacy
addresses).

Keep the static ULA address — it remains the stable ingress address.

Change from:

```nix
networkConfig = {
  Address = [host.cidr4 host.cidr6];
  IPv6AcceptRA = false;
  DHCP = "no";
};
```

To:

```nix
networkConfig = {
  Address = [host.cidr4 host.cidr6];  # Keep both static addresses
  IPv6AcceptRA = true;                # Accept RAs for SLAAC privacy addresses
  DHCP = "no";                        # IPv4 stays static
  IPv6PrivacyExtensions = "yes";      # Generate + prefer temporary addresses for egress
};
```

Note on `accept_ra` sysctl: The kernel default `accept_ra = 1` works for hosts
that don't forward packets. For hosts that have `net.ipv6.conf.*.forwarding = 1`
(e.g., VM hosts that forward traffic to guests), `accept_ra = 2` is needed to
accept RAs despite forwarding being enabled. Only add the sysctl override on
hosts that forward.

### 2. Source address selection (egress prefers SLAAC)

`IPv6PrivacyExtensions = "yes"` in systemd-networkd sets the kernel's
`use_tempaddr = 2`, which means:

- Generate SLAAC temporary addresses (RFC 8981)
- Prefer temporary addresses for outgoing connections (RFC 6724 source address
  selection)

The stable static ULA address is used for ingress because:

- DNS AAAA records point to it (via `mkUnboundLocalData`)
- Services bind to `::` (all addresses) or specifically to the ULA address
- Clients connect to the host via DNS, which resolves to the stable address
- The kernel never selects the static address for outgoing connections because
  RFC 6724 prefers temporary addresses when `use_tempaddr = 2`

No `ip rule`, `gai.conf`, or other changes needed.

### 3. Handle forwarding hosts

VM hosts (remiferia, calvard, erebonia) and the router itself have IP forwarding
enabled. The Linux kernel ignores RAs when forwarding is enabled unless
`accept_ra = 2`. For these hosts, add:

```nix
boot.kernel.sysctl."net.ipv6.conf.<iface>.accept_ra" = 2;
```

MicroVM guests and Incus guests generally don't forward, so they don't need this.

### 4. Verify router6 RA configuration

The router6 module already sends RAs on interfaces with `dhcp6.enable = true`.
Thebeyond's `mkVlanBridge` sets `dhcp6.enable = true` on all VLANs by default.
The current mode is `slaac` (default), which sets `Managed = false` and
`OtherInformation = false` — this is correct for this plan. Hosts get SLAAC
addresses from the advertised ULA prefix.

No router6 module changes needed. The RA prefixes already include the ULA /64
for each VLAN.

### 5. Integration test

**New file:** `tests/modules/router6-ipv6-privacy.nix`

Test topology:

- Router with one VLAN using `dhcp6.enable = true` (default `slaac` mode)
- Client with a static ULA address + `IPv6AcceptRA = true` + `IPv6PrivacyExtensions = "yes"`

Verify:

1. Client has the static ULA address (stable ingress)
2. Client has at least one SLAAC temporary address (privacy egress)
3. Client has at least two non-link-local IPv6 addresses on the interface
4. Client can ping router via the stable ULA address
5. The SLAAC address is in the correct /64 prefix

Wire into `tests/router6.nix`.

## Files to modify

Host configs — enable RA acceptance + privacy extensions:

VM hosts (need `accept_ra = 2` — they forward traffic to guests):

- `hosts/remiferia/default.nix`
- `hosts/calvard/microvm/default.nix`
- `hosts/erebonia/microvm/default.nix`

MicroVM guests:

- `hosts/thebeyond/microvm/guests/phantasma/default.nix`
- `hosts/calvard/microvm/guests/messeldam/default.nix`
- `hosts/calvard/microvm/guests/langport/default.nix`
- `hosts/erebonia/microvm/guests/saint-arkh/default.nix`

Incus guests:

- `hosts/calvard/incus/guests/edith/default.nix`
- `hosts/calvard/incus/guests/oracion/default.nix`
- `hosts/erebonia/incus/guests/trista/default.nix`

Test files:

- `tests/modules/router6-ipv6-privacy.nix` (create)
- `tests/router6.nix` (add entry)

## Follow-up: Stable GUA addresses + ULA address offset

When prefix delegation is deployed, see the separate plan:
`plans/ipv6-gua-stable-ingress.md`.

That plan:

- Adds stable GUA addresses to all hosts via SLAAC `Token` mechanism
- Shifts ULA host IDs from `::XX` to `::a0XX` to match GUA (scan resistance
  for GUA, consistency for both)
- Requires this plan to be deployed first (hosts must accept RAs)

## Verification

```bash
# Run the new privacy extensions test
nix build .#checks.x86_64-linux.router6-ipv6-privacy --print-build-logs

# Regression: existing IPv6 + DHCPv6 tests still pass
nix build .#checks.x86_64-linux.router6-ipv6 --print-build-logs
nix build .#checks.x86_64-linux.router6-dhcpv6 --print-build-logs

# All checks
./scripts/run-checks.sh -j1
```
