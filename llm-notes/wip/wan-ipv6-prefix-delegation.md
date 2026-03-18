# Plan: WAN IPv6 with DHCPv6 Prefix Delegation

## Context

The router6 module has solid internal IPv6 support (ULA addressing, SLAAC/RA, Kea DHCPv6 server) but no WAN-side IPv6. Clients only get ULA addresses — they can't reach the IPv6 internet. This plan adds DHCPv6-PD (Prefix Delegation) support so the router can request a public IPv6 prefix from the ISP and distribute /64 subnets to internal VLANs.

### Design philosophy

This is an opinionated module following IPv6 best practices:

- **No NAT66/masquerade for IPv6.** IPv6 endpoints use globally-routable addresses. The firewall provides security, not address translation.
- **Dual-stack by default.** Internal interfaces get both ULA (stable, always available) and GUA (global, ISP-dependent) prefixes. ULA provides internal connectivity even if the ISP link is down.
- **systemd-networkd does the heavy lifting.** It handles DHCPv6-PD client, prefix pool management, delegated prefix distribution, and RA updates — all natively.
- **No IPv6 masquerade rule.** The existing `ip6 nat` table stays empty (escape hatches remain for advanced users). IPv6 traffic is forwarded with original source addresses.

### How systemd-networkd PD works

1. **WAN interface**: `dhcpV6Config.PrefixDelegationHint = "::/XX"` tells the ISP what prefix size we want
2. **LAN interfaces**: `networkConfig.DHCPPrefixDelegation = true` tells networkd to allocate a /64 from the delegated pool
3. **Subnet selection**: `dhcpPrefixDelegationConfig.SubnetId = "0xNN"` picks which /64 from the pool
4. **Router address**: `dhcpPrefixDelegationConfig.Token = "::1"` gives the router `<prefix>::1` on each subnet
5. **RA integration**: `IPv6SendRA = true` automatically advertises delegated prefixes alongside any static (ULA) prefixes

When the ISP renews or changes the prefix, systemd-networkd updates addresses and RA prefixes automatically.

## Changes

### 1. Refactor: decouple RA behavior from `type` (prerequisite)

**Problem:** The `type` field (`"dhcp"`, `"static"`, `"disabled"`) currently controls two unrelated things:

1. **Address assignment method** — how the interface gets its IPv4 address (legitimate)
2. **IPv6 RA direction** — whether the interface sends or accepts Router Advertisements (should be driven by explicit options)

This conflation makes the PD feature awkward — adding PD would require `shouldSendRA` to grow yet another `&& type == "static"` guard. More importantly, it makes the config hard to reason about: you can't tell from `type = "static"` that it controls RA behavior.

**Fix:** Let explicit options drive RA behavior. `type` only controls address assignment.

#### 1a. `shouldSendRA` — drop `type == "static"` guard

**File:** `modules/router6/default.nix`, line 1183

Before:

```nix
shouldSendRA = (network.dhcp6.enable or false) && network.type == "static";
```

After:

```nix
shouldSendRA = (network.dhcp6.enable or false) || (network.pdSubnetId or null) != null;
```

The explicit options (`dhcp6.enable`, `pdSubnetId`) are now the sole signals for "send RAs on this interface." No `type` guard.

#### 1b. `IPv6AcceptRA` — drive from explicit options

**File:** `modules/router6/default.nix`, line 1202

Before:

```nix
IPv6AcceptRA = network.type == "dhcp";
```

After:

```nix
IPv6AcceptRA = network.type == "dhcp" || (network.ipv6PrefixDelegation.enable or false);
```

This accommodates a future scenario where PD is on a non-DHCP interface (e.g. static WAN IP but still requesting PD). In practice, PD interfaces are almost always `type = "dhcp"`, so this is a no-op today but prevents a confusing failure mode.

#### 1c. `raInterfaces` (accept_ra sysctl) — match `IPv6AcceptRA` logic

**File:** `modules/router6/default.nix`, line 282

Before:

```nix
raInterfaces = interfacesWhere (i: i.network.type == "dhcp");
```

After:

```nix
raInterfaces = interfacesWhere (i:
  i.network.type == "dhcp" || (i.network.ipv6PrefixDelegation.enable or false));
```

Must stay in sync with `IPv6AcceptRA` — the sysctl `accept_ra = 2` is required for any interface that accepts RAs.

#### 1d. `ipv6SendRAConfig` guard — handle PD-only interfaces

**File:** `modules/router6/default.nix`, line 1236

Currently guarded by `shouldSendRA && v6Addrs != []`. The `v6Addrs != []` check is needed because the block accesses `head v6Addrs` for the DNS address. With PD, an interface might have `pdSubnetId` but no static IPv6 address (if it only receives a delegated prefix).

Change the `ipv6SendRAConfig` block to handle this:

```nix
// optionalAttrs shouldSendRA {
  ipv6SendRAConfig = {
    Managed = dhcp6Mode == "stateful";
    OtherInformation = dhcp6Mode == "stateless";
    RouterLifetimeSec = 1800;
  }
  // optionalAttrs (v6Addrs != []) {
    # Advertise DNS server (the router's ULA address on this interface)
    EmitDNS = true;
    DNS = (parseCIDR (head v6Addrs)).ip;
  };

  # Advertise static IPv6 prefixes for SLAAC (ULA)
  # Delegated prefixes are announced automatically by DHCPPrefixDelegation
  ipv6Prefixes =
    map (addr: let
      parsed = parseCIDR addr;
      ipParts = lib.splitString "::" parsed.ip;
      networkPrefix = "${head ipParts}::/${toString parsed.prefix}";
    in {
      Prefix = networkPrefix;
      PreferredLifetimeSec = 3600;
      ValidLifetimeSec = 7200;
    })
    v6Addrs;
}
```

Key changes:

- `ipv6SendRAConfig` is emitted whenever `shouldSendRA` is true (not gated on `v6Addrs != []`)
- `EmitDNS`/`DNS` are conditionally included only when v6Addrs exist
- `ipv6Prefixes` can be empty (PD-only interface) — delegated prefixes are announced separately by systemd-networkd's `DHCPPrefixDelegation`
- The outer guard changes from `shouldSendRA && v6Addrs != []` to just `shouldSendRA`

#### 1e. Add assertions for contradictory combinations

**File:** `modules/router6/default.nix`, in the `config = mkIf cfg.enable` block

```nix
assertions = [
  {
    assertion = !(lib.any (i:
      (i.network.dhcp6.enable or false) && i.network.type == "dhcp"
    ) flattenTopology);
    message = "router6: dhcp6.enable (RA server) cannot be set on a DHCP client interface — it would send RAs upstream to the ISP";
  }
];
```

This catches the misconfiguration where someone enables the DHCPv6 _server_ (RA + Kea) on a WAN interface. `ipv6PrefixDelegation` on a DHCP interface is fine (that's the client side), but `dhcp6.enable` on a DHCP interface would send RAs to the ISP.

#### 1f. Verify with existing tests

This refactoring must not change any existing behavior. All existing tests should pass unchanged:

- `router6-ipv6`: uses `dhcp6.enable = true` on a static VLAN — RA behavior unchanged
- `router6-dhcpv6`: uses `dhcp6.enable = true` with stateful/stateless modes — unchanged
- `router6-wan-dhcp`: uses `type = "dhcp"` on WAN — no `dhcp6.enable`, so `shouldSendRA` remains false; `IPv6AcceptRA` remains true
- `router6-firewall`, `router6-firewall-zones`, etc.: no IPv6 RA config — unchanged

### 2. Add `ipv6PrefixDelegation` option to network submodule

**File:** `modules/router6/default.nix`, in `mkNetworkSubmodule` (~line 142, after `dhcp6`)

Add a new option for WAN interfaces to request prefix delegation:

```nix
ipv6PrefixDelegation = mkOption {
  description = "Request IPv6 prefix delegation on this WAN interface";
  type = types.submodule {
    options = {
      enable = mkEnableOption "DHCPv6 Prefix Delegation client";
      prefixLength = mkOption {
        type = types.int;
        default = 48;
        description = "Prefix length to request from ISP (e.g. 48, 56, 60)";
      };
    };
  };
  default = {};
};
```

This goes on WAN/DHCP interfaces — it's the _client_ side requesting a prefix.

### 3. Add `pdSubnetId` option to network submodule

**File:** `modules/router6/default.nix`, in `mkNetworkSubmodule` (near `subnetId`)

Add an option for LAN interfaces to receive a delegated subnet:

```nix
pdSubnetId = mkOption {
  type = types.nullOr types.str;
  default = null;
  description = ''
    Hex subnet ID for prefix delegation (e.g. "0xa" for VLAN 10).
    When set, this interface receives a /64 from the delegated prefix pool.
    The router gets <prefix>::1 on this subnet.
    Requires a WAN interface with ipv6PrefixDelegation.enable = true.
  '';
  example = "0xa";
};
```

Design decision: use explicit `pdSubnetId` rather than auto-deriving from `subnetId`/VLAN tag. Reasons:

- PD subnet IDs must be hex strings for systemd-networkd's `SubnetId` option
- The available range depends on the delegated prefix size (e.g. /56 gives 0x00-0xff, /48 gives 0x0000-0xffff)
- Not all internal interfaces should receive a delegated prefix (e.g. management VLAN may be ULA-only)
- Explicit is better than implicit for a security-relevant feature (public addresses)

### 4. Wire WAN interface DHCPv6-PD client config

**File:** `modules/router6/default.nix`, in `mkNetworkConfig`

For WAN interfaces with `ipv6PrefixDelegation.enable`, add:

```nix
# Add dhcpV6Config section to the network unit:
dhcpV6Config = optionalAttrs (network.ipv6PrefixDelegation.enable or false) {
  PrefixDelegationHint = "::/${toString network.ipv6PrefixDelegation.prefixLength}";
  # Always send DHCPv6 solicits, even if ISP RA doesn't set M flag.
  # Many ISPs don't set Managed=true in RAs but still support PD.
  WithoutRA = "solicit";
  # Don't use ISP-provided DNS — we run our own resolver
  UseDNS = false;
  UseHostname = false;
};
```

This tells systemd-networkd to include an IA_PD request in DHCPv6 solicitations.

Key: `WithoutRA = "solicit"` ensures DHCPv6 solicitations are sent even if the ISP's RA doesn't set the Managed flag. Many ISPs send RAs with M=0 but still support prefix delegation — without this, systemd-networkd would never trigger DHCPv6 and PD would silently fail. This is the robust approach used by production deployments.

Note: `IPv6AcceptRA = true` is already set for DHCP interfaces (and now also for PD interfaces per step 1b). The `accept_ra = 2` sysctl is already configured per step 1c.

### 5. Wire LAN interface prefix delegation receiver

**File:** `modules/router6/default.nix`, in `mkNetworkConfig`

For interfaces with `pdSubnetId != null`, add:

```nix
# In networkConfig section:
// optionalAttrs ((network.pdSubnetId or null) != null) {
  DHCPPrefixDelegation = true;
}

# Add dhcpPrefixDelegationConfig section:
dhcpPrefixDelegationConfig = optionalAttrs ((network.pdSubnetId or null) != null) {
  SubnetId = network.pdSubnetId;
  Token = "::1";  # Router gets <prefix>::1 on each subnet (matches ULA convention)
  Announce = true;  # Include in RA (default, but explicit for clarity)
  Assign = true;  # Assign address to this interface
};
```

Key points:

- `Token = "::1"` ensures the router's GUA address matches the ULA convention (gateway is always `::1`)
- `Announce = true` means the delegated /64 prefix is automatically included in RAs alongside the static ULA prefix
- systemd-networkd handles prefix lifecycle: when ISP prefix changes, addresses and RA prefixes update automatically
- `IPv6SendRA = true` is already set by `shouldSendRA` (from step 1a, triggered by `pdSubnetId != null`)

### 6. Handle firewall for delegated prefixes (no changes needed)

No changes needed for basic forwarding — the zone-based firewall already operates on interface names, not addresses. Traffic from `trusted` zone interfaces is forwarded to `external` zone interfaces regardless of whether it's ULA or GUA sourced.

The existing nftables rules already handle:

- Forward chain: zone-based interface matching (works for any addresses)
- Input chain: zone-based service access (works for any addresses)
- ICMPv6: NDP and basic ICMPv6 always allowed
- Connection tracking: `ct state established,related accept` (works for IPv6)

What's explicitly **not** added (opinionated):

- No `ip6 nat postrouting masquerade` rule for IPv6 — traffic is forwarded with original GUA source
- No DNAT for IPv6 — hosts are directly reachable via GUA (firewall controls access)

### 7. Add integration test

**New file:** `tests/modules/router6-wan-ipv6-pd.nix`

Test topology (extends the WAN DHCP test pattern):

- **ISP node**: Kea DHCPv6 server with PD pool + radvd for RAs (mirrors the nixpkgs upstream test at `nixos/tests/systemd-networkd-ipv6-prefix-delegation.nix`)
  - PD pool: `2001:db8:1000::/36` delegating /48 prefixes
  - RA: Managed flag set, advertising `::/64` prefix
  - Kea run-script hook to install routes for delegated prefixes
- **Router**: WAN with `ipv6PrefixDelegation.enable = true`, two LAN interfaces with `pdSubnetId`
  - LAN1 (trusted): `pdSubnetId = "0x1"`, `dhcp6.enable = true`, `dhcp6.mode = "stateful"`
  - LAN2 (iot): `pdSubnetId = "0x2"`, `dhcp6.enable = true`, `dhcp6.mode = "slaac"`
- **Client**: On LAN1, accepts RAs

Test steps:

1. ISP boots, Kea DHCPv6 + radvd ready
2. Router boots, gets delegated /48 prefix from ISP
3. Router has GUA address on LAN1 (`<delegated>::1`) and ULA address
4. Client gets GUA via SLAAC from delegated prefix
5. Client gets ULA via SLAAC from static ULA prefix
6. Client can ping ISP's address (`2001:db8::1`) — verifies end-to-end forwarding with GUA
7. Client can ping router's ULA — verifies ULA still works alongside GUA
8. No masquerade rule in `ip6 nat` table — verify opinionated no-NAT66

Wire into `tests/router6.nix` as `router6-wan-ipv6-pd`.

### 8. DHCPv6 reservations (follow-up, not in this PR)

The plan doc for DHCPv6 Kea integration mentioned "each internal host will get a static IPv6 for ingress." Now that Kea DHCPv6 is running, a follow-up should add `dhcp6.reservations` (DUID-based, parallel to `dhcp.reservations` for IPv4). This is independent of PD and can be done separately.

## Files to modify

1. `modules/router6/default.nix` — Refactor RA logic (step 1), new options (steps 2-3), WAN DHCPv6-PD client config (step 4), LAN PD receiver config (step 5), assertion (step 1e)
2. `tests/modules/router6-wan-ipv6-pd.nix` — New integration test (create)
3. `tests/router6.nix` — Add the new test entry

## Usage example

```nix
router6 = {
  enable = true;
  ulaPrefix = "fdc6:55f2:0a5e::/48";

  topology = {
    wan = {
      hardwareName = "eth0";
      network = {
        type = "dhcp";
        zone = "external";
        nat.enable = true;       # IPv4 masquerade only
        defaultRoute = true;
        ipv6PrefixDelegation = {
          enable = true;
          prefixLength = 56;     # Request /56 from ISP
        };
      };
    };
    eth1 = {
      hardwareName = "eth1";
      network = {
        type = "disabled";
        required = false;
      };
      vlans = {
        vlan10 = {
          tag = 10;
          network = {
            type = "static";
            addresses = ["10.0.10.1/24"];
            zone = "trusted";
            dhcp.enable = true;
            dhcp6 = { enable = true; mode = "stateful"; };
            pdSubnetId = "0xa";  # Gets <isp-prefix>:a::/64
          };
        };
        vlan20 = {
          tag = 20;
          network = {
            type = "static";
            addresses = ["10.0.20.1/24"];
            zone = "iot";
            dhcp.enable = true;
            dhcp6 = { enable = true; mode = "slaac"; };
            pdSubnetId = "0x14"; # Gets <isp-prefix>:14::/64
          };
        };
        vlan100 = {
          tag = 100;
          network = {
            type = "static";
            addresses = ["10.0.100.1/24"];
            zone = "management";
            dhcp.enable = true;
            dhcp6 = { enable = true; mode = "slaac"; };
            # No pdSubnetId — management stays ULA-only (no public addresses)
          };
        };
      };
    };
  };
};
```

Result for a client on VLAN 10:

- ULA address: `fdc6:55f2:0a5e:a::<random>/64` (SLAAC from static ULA prefix, always available)
- GUA address: `<isp-prefix>:a::<random>/64` (SLAAC from delegated prefix, for internet access)
- DHCPv6 address: `fdc6:55f2:0a5e:a::1000-1fff` (Kea, stable address for ingress)

## Verification

```bash
# Run existing tests first (refactoring regression check)
nix build .#checks.x86_64-linux.router6-ipv6 --print-build-logs
nix build .#checks.x86_64-linux.router6-dhcpv6 --print-build-logs
nix build .#checks.x86_64-linux.router6-wan-dhcp --print-build-logs

# Run the new PD test
nix build .#checks.x86_64-linux.router6-wan-ipv6-pd --print-build-logs

# Run all checks
./scripts/run-checks.sh -j4
```

## Research sources

- [NixOS nixpkgs PD test](https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/systemd-networkd-ipv6-prefix-delegation.nix) — canonical reference for ISP simulation + router + client topology
- [Major Hayden: DHCPv6 PD with systemd-networkd](https://major.io/p/dhcpv6-prefix-delegation-with-systemd-networkd/)
- [blog.g3rt.nl: systemd-networkd DHCPv6-PD](https://blog.g3rt.nl/systemd-networkd-dhcpv6-pd-configuration.html) — SubnetId, Token, ForceDHCPv6PDOtherInformation
- [NixOS 22.11 Router with PD gist](https://gist.github.com/mweinelt/b78f7046145dbaeab4e42bf55663ef44) — NixOS-specific attribute names, multi-VLAN PD
- [Erik Nygren: DHCPv6-PD on Ubuntu](https://erik.nygren.org/dhcpv6-pd-on-ubuntu-2204.html) — SubnetId/Token details
- [systemd.network(5) man page](https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html) — canonical reference
