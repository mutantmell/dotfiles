# Zone-Based Firewall Refactor Plan

## Overview

Replace the hardcoded trust enum in the router6 module with a user-configurable
`zones` attrset. This is inspired by OpenWRT's zone/forwarding model but fits
naturally into the Nix module system.

This is a **pure refactor**: the generated nftables output for the current
configuration must be identical before and after. No VLAN topology changes,
no new networks, no IP address changes.

### Why separate this from the secure-mgmt-vlan plan?

The zone refactor is a prerequisite for the VLAN split, but it:

- Has its own risk profile (firewall misconfiguration can break everything)
- Can be tested independently without any network topology changes
- Is large enough to deserve focused attention
- Produces identical behavior when done correctly — a clean refactor

The [secure-mgmt-vlan-plan](./secure-mgmt-vlan-plan.md) consumes the zone
system starting from its Phase 2.

---

## Phase 0: Pre-Refactor Test Coverage

Before refactoring the trust system into zones, add tests that verify the current firewall behavior across all trust levels. These tests ensure the zone refactor produces identical nftables output.

### 0.1 New integration test: `router6-firewall-zones`

**File:** `tests/modules/router6-firewall-zones.nix`

A comprehensive multi-zone test with all current trust levels represented:

```nix
nodes = {
  router = {
    imports = [ ../../modules/router6 ];
    virtualisation.vlans = [ 1 2 3 4 5 ];

    router6 = {
      enable = true;
      ulaPrefix = "fdc6:55f2:0a5e::/48";
      dns.upstream = [ "1.1.1.1" ];
      dns.useDHCPFallback = false;
      dns.localDomain = "test.local";

      topology = {
        eth1 = {
          hardwareName = "eth1";
          network = {
            type = "static";
            addresses = [ "203.0.113.1/24" ];
            trust = "external";
            nat.enable = true;
          };
        };
        eth2 = {
          hardwareName = "eth2";
          network = {
            type = "static";
            addresses = [ "10.0.10.1/24" ];
            trust = "management";
            dhcp.enable = true;
          };
        };
        eth3 = {
          hardwareName = "eth3";
          network = {
            type = "static";
            addresses = [ "10.0.20.1/24" ];
            trust = "trusted";
            dhcp.enable = true;
          };
        };
        eth4 = {
          hardwareName = "eth4";
          network = {
            type = "static";
            addresses = [ "10.0.30.1/24" ];
            trust = "untrusted";
            dhcp.enable = true;
          };
        };
        eth5 = {
          hardwareName = "eth5";
          network = {
            type = "static";
            addresses = [ "10.0.40.1/24" ];
            trust = "isolated";
          };
        };
      };
    };
  };

  # One node per trust zone
  mgmt    = { ... };  # 10.0.10.100 on VLAN 2
  trusted = { ... };  # 10.0.20.100 on VLAN 3
  guest   = { ... };  # 10.0.30.100 on VLAN 4
  isolated = { ... }; # 10.0.40.100 on VLAN 5
  attacker = { ... }; # 203.0.113.100 on VLAN 1
};
```

**Test cases (each becomes a named test function):**

Input chain tests:
1. **management → router: full access** — mgmt can reach all router ports (SSH, DNS, any service)
2. **trusted → router: full access** — trusted can reach all router ports
3. **untrusted → router: DNS/DHCP only** — guest can reach DNS (53/tcp, 53/udp) and DHCP (67/udp) but NOT SSH (22/tcp) or HTTP (80/tcp)
4. **isolated → router: nothing** — isolated node cannot reach any router port (not even DNS/DHCP)
5. **external → router: stealth** — attacker gets nothing (already covered by existing test, but good to have in the matrix)
6. **ICMP echo: internal only** — mgmt/trusted/untrusted can ping router; external/isolated cannot

Forward chain tests:
7. **management → trusted: allowed** — mgmt can reach trusted node
8. **management → untrusted: allowed** — mgmt can reach guest node
9. **management → external: allowed** — mgmt can reach internet (via NAT)
10. **trusted → management: allowed** — trusted can reach mgmt node
11. **trusted → untrusted: allowed** — trusted can reach guest node
12. **trusted → external: allowed** — trusted can reach internet
13. **untrusted → external: allowed** — guest can reach internet
14. **untrusted → management: blocked** — guest cannot reach mgmt node
15. **untrusted → trusted: blocked** — guest cannot reach trusted node
16. **isolated → anything: blocked** — isolated cannot forward anywhere
17. **external → internal: blocked** — attacker cannot reach any internal network

### 0.2 Snapshot the nftables ruleset

Add a test that captures the generated nftables ruleset as a string and compares it against a golden file. This provides a safety net: after the zone refactor, the generated ruleset for the same logical configuration should be identical (or functionally equivalent).

**Approach:** A unit test (pure Nix evaluation) that evaluates the router6 module config and extracts `config.networking.nftables.ruleset`, then compares against a stored expected output.

**File:** `tests/lib/router6-firewall-snapshot.nix`

```nix
# Evaluate a minimal router6 config and verify the generated nftables ruleset
let
  result = (lib.nixosSystem {
    modules = [
      ../../modules/router6
      { router6 = { /* same config as test above */ }; }
    ];
  }).config.networking.nftables.ruleset;
in
  assert result == builtins.readFile ./expected-ruleset.nft;
  "PASS"
```

This test will fail after the zone refactor if the output changes, forcing us to verify any differences are intentional.

---

## Phase 1: Zone-Based Firewall Refactor

Replace the hardcoded trust enum with a user-configurable `zones` attrset. This is inspired by OpenWRT's zone/forwarding model but fits naturally into the Nix module system.

### 1.1 Zone configuration schema

**File:** `modules/router6/default.nix`

Add a new top-level option `router6.zones`:

```nix
zones = mkOption {
  description = ''
    Firewall zone definitions. Each zone defines:
    - accessTo: which zones this zone can freely forward traffic to
    - forwardRules: per-destination-zone nftables rules (for filtered forwarding)
    - inputRules: nftables rules for traffic from this zone to the router itself
    - icmpEcho: whether the zone can ping the router

    Networks reference zones via their `zone` field (required on every network).
  '';
  default = {};
  example = {
    wan = {
      icmpEcho = "disable";
      accessTo = [];
      inputRules = [];
    };
    lan = {
      icmpEcho = "enable";
      accessTo = [ "wan" ];
      inputRules = [
        { verdict = "accept"; }
      ];
    };
  };
  type = types.attrsOf (types.submodule ({ name, ... }: {
    options = {

      icmpEcho = mkOption {
        type = types.enum [ "enable" "ipv4-only" "ipv6-only" "disable" ];
        default = "disable";
        description = ''
          Whether interfaces in this zone can ping the router.
          - "enable": allow ICMPv4 + ICMPv6 echo-request/echo-reply
          - "ipv4-only": allow only ICMPv4 echo
          - "ipv6-only": allow only ICMPv6 echo
          - "disable": no ICMP echo (PMTUD and NDP are always allowed by baseRules)
        '';
      };

      accessTo = mkOption {
        type = types.listOf (types.enum (builtins.attrNames cfg.zones));
        default = [];
        description = ''
          Zones this zone can freely forward traffic to (blanket accept).
          A zone listed here means: all interfaces in this zone can reach
          all interfaces in the target zone.

          Values are restricted to defined zone names (validated by type).
        '';
        example = [ "trusted" "untrusted" "external" ];
      };

      forwardRules = mkOption {
        type = types.attrsOf (types.listOf nftRuleType);
        default = {};
        description = ''
          Per-destination-zone forwarding rules. Keys are target zone names,
          values are lists of nftables rules (same DSL as extraForwardRules).

          Rules must NOT specify iifname or oifname — these are automatically
          set from the source and destination zone's interfaces.

          A destination zone must NOT also appear in accessTo (assertion enforced).
          Keys are validated by assertion to be defined zone names.
        '';
        example = {
          external = [
            { tcp.dport = 443; verdict = "accept"; comment = "HTTPS for updates"; }
            { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
            { verdict = "drop"; comment = "Block all other egress"; }
          ];
        };
      };

      inputRules = mkOption {
        type = types.listOf nftRuleType;
        default = [];
        description = ''
          Rules for traffic from this zone's interfaces to the router itself.
          Same DSL as extraInputRules but must NOT specify iifname — it is
          automatically set from the zone's interfaces.
        '';
        example = [
          { udp.dport = [ 53 67 ]; verdict = "accept"; comment = "DNS + DHCP"; }
          { tcp.dport = 53; verdict = "accept"; comment = "DNS over TCP"; }
        ];
      };

    };
  }));
};
```

**Type-level validation notes:**

- `accessTo` uses `types.enum (builtins.attrNames cfg.zones)` — Nix laziness makes this
  self-reference work (zone keys are known at definition time, values checked at eval time).
  This means invalid zone names in `accessTo` produce a type error, no assertion needed.
- `zone` on networks (Phase 1.3) uses the same `types.enum` trick.
- `forwardRules` uses `types.attrsOf` which accepts any string key — we validate keys via
  assertion (Phase 1.6) since `types.attrsOf` doesn't support restricting key names.
- `inputRules` doesn't reference zones, so no special validation needed.

### 1.2 Global defaults option

**File:** `modules/router6/default.nix`

Add an option to control the hardcoded global rules (ICMP, connection tracking, etc.):

```nix
firewall.baseRules = mkOption {
  type = types.bool;
  default = true;
  description = ''
    Include base firewall rules that zones build on top of:
    - Connection tracking (ct state established,related accept)
    - Loopback accept
    - Essential ICMP/ICMPv6 (PMTUD, Neighbor Discovery)
    - TCP MSS clamping in forward chain
    When false, only zone-defined rules and extra*Rules are generated.
  '';
};
```

### 1.3 Rename `trust` to `zone`, make required

**File:** `modules/router6/default.nix` — `mkNetworkSubmodule`

Replace the hardcoded enum with a required zone reference:
```nix
# Before:
trust = mkOption {
  type = types.nullOr (types.enum [
    "external" "management" "trusted" "untrusted" "isolated"
  ]);
  default = null;
  ...
};

# After:
zone = mkOption {
  type = types.enum (builtins.attrNames cfg.zones);
  description = "Firewall zone for this network (must be a key in router6.zones)";
};
```

Every network interface must explicitly declare its zone — no more `null` default. Nix's lazy evaluation ensures this self-reference works: the `zones` attrset keys are known at definition time, and `zone` values are only checked at evaluation time.

This also requires updating all host configs to use `zone = "..."` instead of `trust = "..."`, and updating `interfacesWithTrust` to `interfacesInZone` (reading `i.network.zone` instead of `i.network.trust`).

### 1.4 Zone definitions

The module has no built-in zone defaults (`default = {};`). An OpenWRT-style wan/lan example
is provided on the option for documentation. Each host defines all its zones explicitly.

Our network's zones are defined in `hosts/yggdrasil/default.nix` and reproduce the current
hardcoded behavior:

```nix
router6.zones = {
  external = {
    # WAN: no access to anything, no router services
    icmpEcho = "disable";
    accessTo = [];
    inputRules = [];
  };

  management = {
    # Infrastructure: full router access, can reach all internal + internet
    icmpEcho = "enable";
    accessTo = [ "management" "trusted" "untrusted" "external" ];
    inputRules = [
      { verdict = "accept"; comment = "Full router service access"; }
    ];
  };

  trusted = {
    # User devices: full router access, can reach all internal + internet
    icmpEcho = "enable";
    accessTo = [ "management" "trusted" "untrusted" "external" ];
    inputRules = [
      { verdict = "accept"; comment = "Full router service access"; }
    ];
  };

  untrusted = {
    # Guest/IoT: DNS + DHCP only, internet only, no lateral movement
    icmpEcho = "enable";
    accessTo = [ "external" ];
    inputRules = [
      { udp.dport = [ 53 67 547 ]; verdict = "accept"; comment = "DNS + DHCP"; }
      { tcp.dport = 53; verdict = "accept"; comment = "DNS over TCP"; }
    ];
  };

  isolated = {
    # No forwarding, no router services
    icmpEcho = "disable";
    accessTo = [];
    inputRules = [];
  };
};
```

These produce **identical** nftables output to the current hardcoded logic. The existing
`router6-firewall` test and the new Phase 0 tests validate this.

**ICMP echo handling:** The `icmpEcho` option replaces the old approach of manually adding
ICMP echo rules to each zone's `inputRules`. The nftables generation (Phase 1.5) emits the
appropriate `icmp type { echo-request, echo-reply } accept` and/or `icmpv6 type { ... } accept`
rules based on the `icmpEcho` value, before any `inputRules` for that zone. Essential ICMP
(PMTUD, NDP) remains in `baseRules` and is always allowed regardless of `icmpEcho`.

### 1.5 Rewrite nftables generation

**File:** `modules/router6/default.nix` — the `networking.nftables.ruleset` section

Replace the hardcoded interface selectors with zone-driven iteration.

**Remove** the fixed selectors:
```nix
# Remove these:
externalInterfaces = interfacesWithTrust ["management" "trusted" "untrusted"];  # was internalInterfaces
trustedInterfaces = interfacesWithTrust ["management" "trusted"];

# Rename the generic helper:
interfacesInZone = zone:
  interfacesWhere (i: (i.network.zone or null) == zone);
```

**New helper functions:**
```nix
# Get all interfaces for a zone (alias)
zoneInterfaces = zoneName: interfacesInZone zoneName;

# Get all interfaces for a list of zones
zonesInterfaces = zoneNames:
  lib.unique (concatMap zoneInterfaces zoneNames);

# Check if a zone has any interfaces
zoneHasInterfaces = zoneName: zoneInterfaces zoneName != [];

# Active zones (zones that have at least one interface assigned)
activeZones = filter zoneHasInterfaces (attrNames cfg.zones);
```

**Input chain generation:**
```nix
chain input {
  type filter hook input priority filter; policy drop;

  ${optionalString cfg.firewall.baseRules ''
  # Connection tracking
  ct state established,related accept

  # Loopback
  iifname "lo" accept

  # Essential ICMP (PMTUD)
  icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
  icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept

  # IPv6 Neighbor Discovery
  icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
  ''}

  # Zone ICMP echo + input rules
  ${concatStringsSep "\n" (map (zoneName:
    let
      zone = cfg.zones.${zoneName};
      ifaces = zoneInterfaces zoneName;
      ifaceMatch = "iifname ${quoteList ifaces}";
      icmpRules =
        optionalString (zone.icmpEcho == "enable" || zone.icmpEcho == "ipv4-only")
          "${ifaceMatch} icmp type { echo-request, echo-reply } accept\n"
        + optionalString (zone.icmpEcho == "enable" || zone.icmpEcho == "ipv6-only")
          "${ifaceMatch} icmpv6 type { echo-request, echo-reply } accept\n";
    in
      optionalString (ifaces != []) (
        icmpRules
        + concatStringsSep "\n" (map (rule:
            "${ifaceMatch} ${nft.renderRule rule}"
          ) zone.inputRules)
      )
  ) activeZones)}

  # WireGuard ports (per-interface, independent of zones)
  ${optionalString (wgPorts != []) ''
  udp dport { ${concatStringsSep ", " (map toString wgPorts)} } accept
  ''}

  # Extra input rules (escape hatch)
  ${optionalString (cfg.firewall.extraInputRules != []) ''
  ${nft.rulesToStringIndented "  " cfg.firewall.extraInputRules}
  ''}

  # Policy drop handles everything else — no hardcoded zone references
}
```

**Forward chain generation:**
```nix
chain forward {
  type filter hook forward priority filter; policy drop;

  ${optionalString cfg.firewall.baseRules ''
  ct state established,related accept
  tcp flags syn tcp option maxseg size set rt mtu
  ''}

  # Zone forwarding: blanket accessTo rules
  ${concatStringsSep "\n" (map (zoneName:
    let
      zone = cfg.zones.${zoneName};
      srcIfaces = zoneInterfaces zoneName;
      dstIfaces = zonesInterfaces zone.accessTo;
    in
      optionalString (srcIfaces != [] && dstIfaces != [])
        "iifname ${quoteList srcIfaces} oifname ${quoteList dstIfaces} accept"
  ) activeZones)}

  # Zone forwarding: per-destination forwardRules
  ${concatStringsSep "\n" (concatMap (zoneName:
    let
      zone = cfg.zones.${zoneName};
      srcIfaces = zoneInterfaces zoneName;
    in
      mapAttrsToList (dstZone: rules:
        let dstIfaces = zoneInterfaces dstZone;
        in optionalString (srcIfaces != [] && dstIfaces != [] && rules != [])
          (concatStringsSep "\n" (map (rule:
            "iifname ${quoteList srcIfaces} oifname ${quoteList dstIfaces} ${nft.renderRule rule}"
          ) rules))
      ) zone.forwardRules
  ) activeZones)}

  # Port forward accept rules
  ${optionalString (cfg.firewall.portForwards != []) ''
  ${forwardDnatRules}
  ''}

  # Extra forward rules (escape hatch)
  ${optionalString (cfg.firewall.extraForwardRules != []) ''
  ${nft.rulesToStringIndented "  " cfg.firewall.extraForwardRules}
  ''}
}
```

NAT chains remain unchanged — masquerade is per-interface (`nat.enable`), not per-zone.

### 1.6 Assertions

**File:** `modules/router6/default.nix`

Add assertions for the zone system:

```nix
# 1. accessTo and forwardRules must not overlap
assertions = concatMap (zoneName:
  let zone = cfg.zones.${zoneName};
  in map (dstZone: {
    assertion = !elem dstZone zone.accessTo;
    message = "Zone '${zoneName}': destination '${dstZone}' appears in both accessTo and forwardRules. Use one or the other.";
  }) (attrNames zone.forwardRules)
) (attrNames cfg.zones)

# 2. forwardRules keys reference valid zones
# (accessTo is validated at the type level via types.enum — no assertion needed)
++ concatMap (zoneName:
  let zone = cfg.zones.${zoneName};
  in map (target: {
    assertion = hasAttr target cfg.zones;
    message = "Zone '${zoneName}': forwardRules references unknown zone '${target}'";
  }) (attrNames zone.forwardRules)
) (attrNames cfg.zones)

# 3. inputRules must not contain iifname (it's auto-set)
++ concatMap (zoneName:
  let zone = cfg.zones.${zoneName};
  in lib.imap0 (i: rule: {
    assertion = !(isAttrs rule && hasAttr "iifname" rule);
    message = "Zone '${zoneName}': inputRules[${toString i}] must not specify iifname (auto-set from zone interfaces)";
  }) zone.inputRules
) (attrNames cfg.zones)

# 4. forwardRules must not contain iifname or oifname
++ concatMap (zoneName:
  let zone = cfg.zones.${zoneName};
  in concatMap (dstZone:
    lib.imap0 (i: rule: {
      assertion = !(isAttrs rule && (hasAttr "iifname" rule || hasAttr "oifname" rule));
      message = "Zone '${zoneName}': forwardRules.${dstZone}[${toString i}] must not specify iifname/oifname (auto-set from zone interfaces)";
    }) zone.forwardRules.${dstZone}
  ) (attrNames zone.forwardRules)
) (attrNames cfg.zones)

# 5. Remove the old "at least one external interface" assertion — zone names are
# user-defined now, so there's no guaranteed "external" zone.
```

### 1.7 Update existing tests

After the refactor, all Phase 0 tests must still pass. Additionally:

- Update `router6-firewall.nix` to also define zones (or rely on defaults)
- The snapshot test from Phase 0.2 must produce identical output
- Add a new test that uses **custom** zones (not just the defaults) to verify the zone system itself works

### 1.8 Migration of host configs

All host configs must be updated to use `zone = "..."` instead of `trust = "..."`. This is a mechanical find-and-replace across all topology definitions. Since every network interface previously had `trust = "someValue"` (none used `null` in practice), this is straightforward.

Example:
```nix
# Before:
network = { type = "static"; trust = "external"; ... };

# After:
network = { type = "static"; zone = "external"; ... };
```

The existing test configs (`router6-firewall.nix`, etc.) must also be updated.

---

## Complete File Change List

| File | Phase | Changes |
|------|-------|---------|
| `modules/router6/default.nix` | 0, 1 | Add `zones` option, `baseRules` option, rename `trust` to `zone` (required), rewrite nftables generation to iterate zones, add zone assertions |
| `tests/modules/router6-firewall-zones.nix` | 0, 2 | New comprehensive multi-zone firewall test |
| `tests/lib/router6-firewall-snapshot.nix` | 0 | New snapshot test for nftables output stability |
| `tests/default.nix` | 0 | Register new tests |
| `hosts/yggdrasil/default.nix` | 1 | Define zone configs reproducing current trust behavior, change `trust` → `zone` on all interfaces |
| All host configs with `trust =` | 1 | Mechanical rename `trust` → `zone` |
| All test configs with `trust =` | 1 | Mechanical rename `trust` → `zone` |
