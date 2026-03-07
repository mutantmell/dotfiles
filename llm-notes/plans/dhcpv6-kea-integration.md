# Plan: Wire up dhcp6.mode and add Kea DHCPv6 server

## Context

The router6 module has a `dhcp6` option on each network interface with `enable` and `mode` fields. `mode` supports three values (`slaac`, `stateful`, `stateless`) but is currently unused — the RA config is hardcoded to SLAAC behavior (`Managed=false, OtherInformation=false`). The `stateless` and `stateful` modes also require a DHCPv6 server (Kea DHCPv6), which isn't configured at all.

The dead `dhcp6Interfaces` binding has already been removed.

Future direction: each internal host will get a static IPv6 for ingress (from Kea DHCPv6 reservations or manual config) and a SLAAC-derived randomized address for egress privacy. The `stateful` mode supports this — Kea provides the stable address while SLAAC (always enabled via RA prefixes) provides the privacy address.

## Changes

All changes in `modules/router6/default.nix`.

### 1. Wire RA flags to `dhcp6.mode`

**Location:** Lines 1179-1206 (the `ipv6SendRAConfig` block)

Currently hardcoded:
```nix
Managed = false;
OtherInformation = false;
```

Change to derive from `network.dhcp6.mode`:

| Mode | Managed | OtherInformation | Effect |
|------|---------|-------------------|--------|
| `slaac` | false | false | SLAAC only, no DHCPv6 |
| `stateless` | false | true | SLAAC for addresses, DHCPv6 for DNS/options |
| `stateful` | true | false | DHCPv6 for addresses, SLAAC still runs for privacy addresses |

Pass `network.dhcp6.mode` (defaulting to `"slaac"`) into the config block and set flags accordingly.

Note: In all three modes, RA prefixes are still advertised (SLAAC always available for privacy/egress addresses). The `Managed` flag tells clients whether to *also* use DHCPv6 for getting a stable address.

### 2. Add `mkKeaSubnet6` function

**Location:** After `mkKeaSubnet4` (~line 895), add a parallel function.

```nix
mkKeaSubnet6 = iface: let
  effectiveAddrs = getEffectiveAddresses iface;
  v6Addr = firstIPv6 effectiveAddrs;
  parsed = if v6Addr != null then parseCIDR v6Addr else null;
  dhcp6Cfg = iface.network.dhcp6;
in
  if parsed == null then null
  else let
    # Extract network prefix: "fdc6:55f2:0a5e:a::1/64" -> "fdc6:55f2:0a5e:a::"
    ipParts = lib.splitString "::" parsed.ip;
    networkPrefix = "${head ipParts}::";
    # Stable subnet ID from subnetId/VLAN tag (small int, offset to avoid collision with v4 IDs)
    subnetIdNum = iface.network.subnetId or (iface.tag or 1);
  in {
    id = 100000 + subnetIdNum;  # Offset to avoid collision with IPv4 subnet IDs
    subnet = "${networkPrefix}/${toString parsed.prefix}";
    interface = iface.name;
    pools = if dhcp6Cfg.mode == "stateful" then [{
      # DHCPv6 pool: use ::1000 through ::1fff range (avoids ::1 gateway and SLAAC range)
      pool = "${networkPrefix}1000-${networkPrefix}1fff";
    }] else [];  # stateless mode: no address pool, only options
    option-data = [
      { name = "dns-servers"; data = parsed.ip; }  # Router is DNS server
    ] ++ lib.optional (cfg.dns.localDomain != null) {
      name = "domain-search"; data = cfg.dns.localDomain;
    };
  };
```

Key design decisions:
- **Pool range `::1000` to `::1fff`**: Avoids `::1` (gateway), low host IDs (static assignments), and the SLAAC range (which uses interface identifiers or random values in the upper bits). 4096 addresses.
- **ID offset 100000**: IPv4 subnet IDs are derived from `ipv4ToInt` (large numbers like 167772160 for 10.0.0.0), so a small offset is fine — but using 100000+ ensures no overlap with any reasonable scheme.
- **`interface` field**: Required for Kea DHCPv6 since it uses link-local multicast, unlike DHCPv4 which can use broadcast.
- **Stateless mode**: Empty `pools` — Kea only serves options (DNS), not addresses.

### 3. Add `keaSubnets6` and `dhcp6ServerInterfaces`

**Location:** After `keaSubnets` (~line 900)

```nix
dhcp6ServerInterfaces = interfacesWhere (i:
  (i.network.dhcp6.enable or false) && (i.network.dhcp6.mode or "slaac") != "slaac"
);

keaSubnets6 = filter (x: x != null) (map mkKeaSubnet6
  (filter (i: (i.network.dhcp6.enable or false) && (i.network.dhcp6.mode or "slaac") != "slaac") flattenTopology));
```

Only interfaces with `stateful` or `stateless` mode need Kea DHCPv6. Pure `slaac` mode needs no DHCPv6 server.

### 4. Add Kea DHCPv6 service block

**Location:** After the Kea DHCPv4 block (~line 1305)

```nix
(mkIf (keaSubnets6 != []) {
  services.kea.dhcp6 = {
    enable = true;
    settings = {
      interfaces-config = {
        interfaces = dhcp6ServerInterfaces;
      };
      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp6.leases";
      };
      preferred-lifetime = 3600;
      valid-lifetime = 7200;
      renew-timer = 1800;
      rebind-timer = 3600;
      subnet6 = keaSubnets6;
      loggers = [{
        name = "kea-dhcp6";
        output_options = [{ output = "syslog"; }];
        severity = "INFO";
      }];
    };
  };
})
```

### 5. Add integration test

**New file:** `tests/modules/router6-dhcpv6.nix`

Test topology:
- Router with a VLAN using `dhcp6.mode = "stateful"`
- Client configured to accept DHCPv6
- Verify: Kea DHCPv6 service running, client gets DHCPv6 address in the `::1000-::1fff` range, client can ping router, client also gets SLAAC address (both addresses present)

Also add a second VLAN with `dhcp6.mode = "stateless"` to verify:
- Kea running but no address pool for that subnet
- Client gets SLAAC address (not DHCPv6 address)
- RA has `OtherInformation=true`

Wire the new test into `tests/router6.nix`.

## Files to modify

1. `modules/router6/default.nix` — RA flags, mkKeaSubnet6, keaSubnets6, Kea DHCPv6 service block
2. `tests/modules/router6-dhcpv6.nix` — New integration test (create)
3. `tests/router6.nix` — Add the new test entry

## Verification

```bash
# Run the new test
nix build .#checks.x86_64-linux.router6-dhcpv6 --print-build-logs

# Run the existing IPv6 test (regression check — slaac mode unchanged)
nix build .#checks.x86_64-linux.router6-ipv6 --print-build-logs

# Run all checks
./scripts/run-checks.sh -j4
```
