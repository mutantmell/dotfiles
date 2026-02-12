# Secure Management VLAN Split Plan

## Overview

Split the current `vMGMT` (VLAN 10) into two VLANs with distinct security profiles:

- **vMGMT (VLAN 10)** — Networking gear (APs, managed switch). Heavily locked down: no internet, no inter-VLAN access, management SSH only from the router.
- **vINFRA (VLAN 11)** — Infrastructure (NAS, VM hosts, DNS). Moderately locked down: inter-host communication for NFS, internet for self-updating, SSH from router and admin workstation.

**Prerequisite refactor:** Replace the hardcoded trust enum with a configurable zone system (Phase 1), enabling the `network` zone and future extensibility. This is the most fundamental change and occurs first.

### Threat Model

| Device Class | Compromise Risk | Compromise Impact | Lockdown Level |
|---|---|---|---|
| APs / Switch | Higher (exposed to wireless attacks, firmware vulnerabilities) | L2 eavesdropping, MitM on bridged traffic | Maximum: no internet, no lateral movement |
| NAS | Medium (network-exposed services: NFS, SMB) | Data exfiltration, ransomware on shared storage | High: restrict NFS to specific IPs, host firewall |
| VM Hosts | Lower (no exposed services beyond SSH) | Guest VM compromise, pivot to NAS via NFS | High: host firewall, restricted SSH |
| DNS (alfheim) | Lower (MicroVM on router, minimal attack surface) | DNS poisoning, traffic redirection | High: moves to vINFRA, no direct external exposure |

### Architecture: Before and After

**Before:**
```
vMGMT (VLAN 10) — trust: management — 10.0.10.0/24
├── yggdrasil    10.0.10.1   (router)
├── alfheim      10.0.10.2   (DNS MicroVM on yggdrasil)
├── vanaheim     10.0.10.30  (VM host)
├── muspelheim   10.0.10.31  (VM host)
├── jotunheimr   10.0.10.32  (NAS)
└── APs          10.0.10.100-200 (DHCP pool)
    All devices can freely communicate with each other.
    All devices have full access to router services.
    All devices can forward to internet.
```

**After:**
```
vMGMT (VLAN 10) — zone: network — 10.0.10.0/24
├── yggdrasil    10.0.10.1   (router gateway)
└── APs/Switch   10.0.10.100-200 (DHCP pool) or static
    Devices can ONLY reach the router for DHCP/NTP.
    No internet. No access to other VLANs.
    SSH only FROM the router TO the devices.

vINFRA (VLAN 11) — zone: management — 10.0.11.0/24
├── yggdrasil    10.0.11.1   (router gateway)
├── alfheim      10.0.11.2   (DNS MicroVM on yggdrasil)
├── vanaheim     10.0.11.30  (VM host)
├── muspelheim   10.0.11.31  (VM host)
└── jotunheimr   10.0.11.32  (NAS)
    Devices can communicate with each other (NFS, monitoring).
    Internet access for updates (filtered egress).
    SSH from router + admin workstation on vHOME.
```

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

    Networks reference zones via their `zone` field (required on every network).
  '';
  default = {};
  type = types.attrsOf (types.submodule ({ name, ... }: {
    options = {

      accessTo = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Zones this zone can freely forward traffic to (blanket accept).
          A zone listed here means: all interfaces in this zone can reach
          all interfaces in the target zone.
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

### 1.4 Default zone definitions

To preserve backward compatibility, define default zones that reproduce the current hardcoded behavior. These go in the `router6.zones` option default OR as a config set in the module:

```nix
# In the module's config section (not the default, so users can override):
config = mkIf cfg.enable (mkMerge [
  # ... existing config ...

  # Default zone definitions (can be overridden/extended by the user)
  {
    router6.zones = {
      external = {
        # WAN: no access to anything, no router services
        accessTo = [];
        inputRules = [];
      };

      management = {
        # Infrastructure: full router access, can reach all internal + internet
        accessTo = [ "management" "trusted" "untrusted" "external" ];
        inputRules = [
          { verdict = "accept"; comment = "Full router service access"; }
        ];
      };

      trusted = {
        # User devices: full router access, can reach all internal + internet
        accessTo = [ "management" "trusted" "untrusted" "external" ];
        inputRules = [
          { verdict = "accept"; comment = "Full router service access"; }
        ];
      };

      untrusted = {
        # Guest/IoT: DNS + DHCP only, internet only, no lateral movement
        accessTo = [ "external" ];
        inputRules = [
          { udp.dport = [ 53 67 547 ]; verdict = "accept"; comment = "DNS + DHCP"; }
          { tcp.dport = 53; verdict = "accept"; comment = "DNS over TCP"; }
        ];
      };

      isolated = {
        # No forwarding, no router services
        accessTo = [];
        inputRules = [];
      };
    };
  }
]);
```

These defaults produce **identical** nftables output to the current hardcoded logic. The existing `router6-firewall` test and the new Phase 0 tests validate this.

Note: ICMP echo is currently allowed from `internalInterfaces` (management + trusted + untrusted). With zones, this needs to be either:
- Part of each zone's `inputRules` (explicit), or
- Part of the global default rules

Since it's currently tied to the "internal" concept (management + trusted + untrusted but not external or isolated), the cleanest approach is to include ICMP echo rules in each zone's `inputRules`. This keeps the global default rules minimal (only PMTUD/NDP). The default zone definitions above would be extended:

```nix
management.inputRules = [
  { icmp.type = [ "echo-request" "echo-reply" ]; verdict = "accept"; }
  { icmpv6.type = [ "echo-request" "echo-reply" ]; verdict = "accept"; }
  { verdict = "accept"; comment = "Full router service access"; }
];

# (Same for trusted — the blanket accept already covers ICMP,
#  but listing it explicitly is clearer)

untrusted.inputRules = [
  { icmp.type = [ "echo-request" "echo-reply" ]; verdict = "accept"; }
  { icmpv6.type = [ "echo-request" "echo-reply" ]; verdict = "accept"; }
  { udp.dport = [ 53 67 547 ]; verdict = "accept"; comment = "DNS + DHCP"; }
  { tcp.dport = 53; verdict = "accept"; comment = "DNS over TCP"; }
];
```

For management and trusted, the blanket `accept` already covers ICMP, so the explicit ICMP rules are redundant but harmless. For untrusted, ICMP echo must be listed explicitly since there's no blanket accept. For isolated and external, no ICMP echo rules — matching current behavior.

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

  # Zone input rules
  ${concatStringsSep "\n" (map (zoneName:
    let
      zone = cfg.zones.${zoneName};
      ifaces = zoneInterfaces zoneName;
    in
      optionalString (ifaces != [] && zone.inputRules != [])
        (concatStringsSep "\n" (map (rule:
          "iifname ${quoteList ifaces} ${nft.renderRule rule}"
        ) zone.inputRules))
  ) activeZones)}

  # WireGuard ports (per-interface, independent of zones)
  ${optionalString (wgPorts != []) ''
  udp dport { ${concatStringsSep ", " (map toString wgPorts)} } accept
  ''}

  # Extra input rules (escape hatch)
  ${optionalString (cfg.firewall.extraInputRules != []) ''
  ${nft.rulesToStringIndented "  " cfg.firewall.extraInputRules}
  ''}

  # Explicit drop for external zone (before the implicit policy drop,
  # useful for logging differentiation)
  ${let extIfaces = zoneInterfaces "external"; in
    optionalString (extIfaces != [])
      "iifname ${quoteList extIfaces} drop"
  }
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

# 2. accessTo and forwardRules reference valid zones
++ concatMap (zoneName:
  let zone = cfg.zones.${zoneName};
  in map (target: {
    assertion = hasAttr target cfg.zones;
    message = "Zone '${zoneName}': accessTo references unknown zone '${target}'";
  }) zone.accessTo
  ++ map (target: {
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

# 5. Keep existing assertion: at least one external interface
# (could be relaxed to: at least one zone named "external", or removed entirely
#  since zones are user-defined now — but keeping it for safety)
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

## Phase 2: New `network` Zone and vINFRA VLAN

With the zone system in place, adding the `network` zone is just a configuration change.

### 2.1 Define `network` zone

**File:** `hosts/yggdrasil/default.nix` (or in the module defaults)

```nix
router6.zones.network = {
  # Networking gear: NTP only, no internet, no lateral movement
  # APs and switches have static IPs — no DHCP needed
  accessTo = [];
  inputRules = [
    { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
    { icmp.type = [ "echo-request" "echo-reply" ]; verdict = "accept"; }
    { icmpv6.type = [ "echo-request" "echo-reply" ]; verdict = "accept"; }
  ];
};
```

This automatically generates:
- Input: `iifname { "vMGMT.br0" } udp dport 123 accept` (plus ICMP echo)
- Forward: nothing (empty `accessTo`, no `forwardRules`)
- No hardcoded `networkInterfaces` selector needed

### 2.2 Management egress filtering via `forwardRules`

With the zone system, the vINFRA egress filtering that was previously planned as `extraForwardRules` with hardcoded interface names becomes a clean zone-level config:

```nix
router6.zones.management = {
  # Full router access, can reach all internal zones
  accessTo = [ "management" "trusted" "untrusted" ];
  # Filtered internet access (not in accessTo — uses forwardRules instead)
  forwardRules = {
    external = [
      { tcp.dport = 443; verdict = "accept";
        comment = "HTTPS for updates (cache.nixos.org, github)"; }
      { udp.dport = 123; verdict = "accept";
        comment = "NTP to internet pools"; }
      { verdict = "drop";
        comment = "Block all other internet-bound traffic"; }
    ];
  };
  inputRules = [
    { verdict = "accept"; comment = "Full router service access"; }
  ];
};
```

Note: `"external"` is NOT in `accessTo` — instead, `forwardRules.external` provides filtered access. The assertion from Phase 1.6 enforces this mutual exclusion.

### 2.3 Add vINFRA VLAN

**File:** `hosts/yggdrasil/default.nix` — inside `router6.topology.br0.vlans`

```nix
# Infrastructure network - NAS, VM hosts, DNS
"vINFRA.br0" = {
  tag = 11;  # -> fdc6:55f2:0a5e:b::1/64
  network = {
    type = "static";
    addresses = [ "10.0.11.1/24" ];
    subnetId = 11;
    zone = "management";
    dhcp.enable = true;
    dhcp6.enable = true;
  };
};
```

### 2.4 Change vMGMT zone

**File:** `hosts/yggdrasil/default.nix` — existing vMGMT definition

```nix
"vMGMT.br0" = {
  tag = 10;
  network = {
    type = "static";
    addresses = [ "10.0.10.1/24" ];
    subnetId = 10;
    zone = "network";  # Changed from "management"
    # No DHCP — APs and switches have static IPs
  };
};
```

Update the comment from "Management network - trusted devices and infrastructure" to "Network gear - APs and managed switch". Also disable DHCP on vMGMT since APs/switches have static IPs.

### 2.5 Update alfheim MicroVM bridge

**File:** `hosts/yggdrasil/default.nix` — systemd.network for MicroVM tap

Rename alfheim's tap to `vm-11-alfheim` and add a new bridge rule:
```nix
systemd.network.networks."10-vm-infra" = {
  matchConfig.Name = "vm-11-*";
  networkConfig = {
    Bridge = "vINFRA.br0";
    DHCP = "no";
    LinkLocalAddressing = "no";
  };
  linkConfig.RequiredForOnline = "no";
};
```

And in alfheim's microvm.nix:
```nix
microvm.interfaces = [{
  type = "tap";
  id = "vm-11-alfheim";
  mac = "5E:11:AD:01:00:02";
}];
```

Remove the old `vm-10-*` bridge rule since no MicroVMs remain on vMGMT.

### 2.6 Update DNS configuration

**File:** `hosts/yggdrasil/default.nix`

```nix
dns = {
  upstream = [ "10.0.11.2" ];  # Changed from 10.0.10.2
  useDHCPFallback = true;
  localDomain = "local";
};
```

### 2.7 Update DNS interception rules

**File:** `hosts/yggdrasil/default.nix` — `firewall.extraNatRules`

Update alfheim's IP in DNS interception exclusions:
```nix
{
  ip.saddr = { not = "10.0.11.2"; };
  ip.daddr = { not = [ "10.0.11.1" "10.0.11.2" ]; };
  udp.dport = 53;
  verdict = { dnat = "10.0.11.1:53"; };
  comment = "Intercept DNS bypass (UDP)";
}
```

kresd binds to all internal interfaces, so any of the router's IPs works as the DNAT target. The main thing is updating the exclusion IPs so alfheim's traffic isn't redirected.

### 2.8 Update `/etc/hosts`

**File:** `hosts/yggdrasil/default.nix`

```nix
networking.extraHosts = ''
  10.0.11.1 yggdrasil
  10.0.11.1 yggdrasil.local
  10.0.11.2 alfheim
  10.0.11.2 alfheim.local
  10.0.20.30 gridr.local
  10.0.100.40 surtr.local
  10.0.100.50 bragi.local
  10.0.100.51 njord.local
'';
```

### 2.9 Add tests for `network` zone

Add test cases to `router6-firewall-zones.nix`:
- **network → router: NTP only** — can reach UDP 123, cannot reach DNS (53), cannot reach SSH (22), cannot reach DHCP (67)
- **network → any: no forwarding** — cannot reach any other zone
- **network → internet: blocked** — no NAT/forwarding to external

---

## Phase 3: Infrastructure Host Changes

### 3.1 alfheim (DNS MicroVM on yggdrasil)

**File:** `hosts/yggdrasil/guests/alfheim/microvm.nix`

Change tap interface name and MAC:
```nix
microvm.interfaces = [{
  type = "tap";
  id = "vm-11-alfheim";
  mac = "5E:11:AD:01:00:02";
}];
```

**File:** `hosts/yggdrasil/guests/alfheim/default.nix`

Update network configuration:
```nix
systemd.network.networks."20-tap" = {
  matchConfig.Type = "ether";
  matchConfig.MACAddress = "5E:11:AD:01:00:02";
  networkConfig = {
    Address = [ "10.0.11.2/24" ];
    Gateway = "10.0.11.1";
    DNS = [ "127.0.0.1" ];
    IPv6AcceptRA = true;
    DHCP = "no";
  };
};
```

Update `/etc/hosts`:
```nix
networking.extraHosts = ''
  10.0.11.1 yggdrasil.local
  10.0.20.30 gridr.local
  10.0.100.40 surtr.local
'';
```

### 3.2 vanaheim (VM host)

**File:** `hosts/vanaheim/default.nix` — initrd network (for ZFS remote unlock)

Change VLAN 10 to VLAN 11:
```nix
boot.initrd.systemd.network = {
  netdevs."20-enp88s0.11" = {
    netdevConfig.Kind = "vlan";
    netdevConfig.Name = "enp88s0.11";
    vlanConfig.Id = 11;
  };
  networks."20-enp88s0.11" = {
    matchConfig.Name = "enp88s0.11";
    networkConfig.DHCP = "no";
    networkConfig.IPv6PrivacyExtensions = "kernel";
    networkConfig.Address = [ "10.0.11.30/24" ];
    networkConfig.MulticastDNS = true;
    networkConfig.DNS = [ "10.0.11.1" ];
    routes = [{ Gateway = "10.0.11.1"; }];
  };
};
```

**File:** `hosts/vanaheim/microvm.nix` — runtime network

Same pattern: change `.10` to `.11`, update addresses and gateway.

### 3.3 muspelheim (VM host)

**File:** `hosts/muspelheim/default.nix`

Same pattern as vanaheim: `eno1.10` → `eno1.11`, address `10.0.10.31/24` → `10.0.11.31/24`, gateway/DNS `10.0.10.1` → `10.0.11.1`, NFS mounts `10.0.10.32` → `10.0.11.32`.

### 3.4 jotunheimr (NAS)

**File:** `hosts/jotunheimr/default.nix`

Change VLAN 10 to VLAN 11, update addresses/gateway/DNS to 10.0.11.x.

---

## Phase 4: NFS/Storage Hardening

### 4.1 Tighten NFS exports

**File:** `hosts/jotunheimr/nas.nix`

Change subnet-wide exports to per-IP exports for VM hosts:

```nix
services.nfs.server = {
  enable = true;
  exports = ''
    /data/media 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)
    /data/data 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)
    /export/ro/media 10.0.11.0/24(ro) 10.0.20.0/24(ro)
    /export/rw/media 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)
    /export/ro/data 10.0.11.0/24(ro) 10.0.20.0/24(ro)
    /export/rw/data 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)
    /export/rw/backup 10.0.11.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check) 10.1.10.0/24(rw,sync,no_subtree_check,no_root_squash) 10.1.20.0/24(rw,sync,no_subtree_check,no_root_squash)
  '';
};
```

### 4.2 Update NFS mount targets

**File:** `hosts/muspelheim/default.nix`
```nix
fileSystems."/mnt/data".device = "10.0.11.32:/data/data";
fileSystems."/mnt/media".device = "10.0.11.32:/data/media/";
```

---

## Phase 5: Host-Based Firewalls

### 5.1 jotunheimr (NAS)

Replace blanket open ports with source-restricted rules:
```nix
networking.firewall = {
  enable = true;
  extraCommands = ''
    # NFS from VM hosts only
    iptables -A INPUT -s 10.0.11.30 -p tcp --dport 2049 -j ACCEPT
    iptables -A INPUT -s 10.0.11.31 -p tcp --dport 2049 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p tcp --dport 2049 -j ACCEPT

    # SMB from vHOME only
    iptables -A INPUT -s 10.0.20.0/24 -p tcp --dport 445 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p tcp --dport 139 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p udp --dport 137 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p udp --dport 138 -j ACCEPT

    # WSDD from vHOME only
    iptables -A INPUT -s 10.0.20.0/24 -p tcp --dport 5357 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p udp --dport 3702 -j ACCEPT

    # SSH only from router and admin workstation
    iptables -I INPUT -p tcp --dport 22 -s 10.0.11.1 -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -s 10.0.20.0/24 -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -j DROP
  '';
};
```

### 5.2 vanaheim / muspelheim (VM hosts)

SSH only from router and admin workstation:
```nix
networking.firewall = {
  enable = true;
  extraCommands = ''
    iptables -I INPUT -p tcp --dport 22 -s 10.0.11.1 -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -s 10.0.20.0/24 -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -j DROP
  '';
};
```

### 5.3 Admin workstation IP

The above rules use `10.0.20.0/24` as a placeholder. Tighten to a specific IP once a DHCP reservation is configured.

---

## Phase 6: OpenWRT AP Changes

### 6.1 No VLAN changes needed

APs stay on VLAN 10. The trust level change happens on the router side.

### 6.2 NTP server change

**File:** `lib/openwrt/default.nix`

APs need to use the router for NTP since they won't have internet:
```nix
ntp = {
  _type = "timeserver";
  enabled = true;
  enable_server = false;
  server = [ "10.0.10.1" ];
};
```

Add chrony/NTP server to yggdrasil:
```nix
services.chrony = {
  enable = true;
  extraConfig = ''
    allow 10.0.10.0/24
    allow 10.0.11.0/24
  '';
};
```

### 6.3 Host-level input protection

Add nftables rules to AP images restricting SSH to router only:
```sh
nft add table inet filter
nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'
nft add rule inet filter input ct state established,related accept
nft add rule inet filter input iifname "lo" accept
nft add rule inet filter input icmp type echo-request accept
nft add rule inet filter input icmpv6 type '{ nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert }' accept
nft add rule inet filter input ip saddr 10.0.10.1 tcp dport 22 accept
nft add rule inet filter input udp dport 68 accept
```

Keep `nftables` package on APs (remove `firewall4` framework only, not `nftables`).

### 6.4 Managed switch

Same treatment as APs: stays on VLAN 10, host firewall, NTP from router. Must trunk VLAN 11 on ports connected to infra devices.

---

## Phase 7: Deployment

### 7.1 SSH access model

```
Admin workstation (vHOME, 10.0.20.X)
├── Direct SSH to infra devices (vINFRA)
│   Allowed by: trusted zone accessTo includes management zone
│   Host firewall: accepts SSH from 10.0.20.X
│
├── SSH to router (yggdrasil)
│   Direct: SSH to 10.0.20.1 (router's vHOME address)
│
└── SSH to networking gear (vMGMT) via ProxyJump
    Step 1: SSH to yggdrasil
    Step 2: yggdrasil SSH to AP/switch on 10.0.10.X
    Required because: network zone has no forwarding
```

### 7.2 Deployment order

1. VM guests first (lowest risk)
2. VM hosts
3. NAS (ensure NFS exports come back up)
4. Router LAST — use `magic_rollback` with deploy-rs

### 7.3 OpenWRT deployment

Deploy from the router (SSH to APs on 10.0.10.x) or via ProxyJump.

---

## Phase 8: Network Data Updates

### 8.1 Update network.json

**File:** `lib/common/data/network.json`

```json
{
  "hosts": {
    "alfheim": { "ipv4": "10.0.11.2" },
    "jotunheimr": { "ipv4": "10.0.11.32" },
    "muspelheim": { "ipv4": "10.0.11.31" },
    "vanaheim": { "ipv4": "10.0.11.30" },
    "yggdrasil": { "ipv4": "10.0.11.1" }
  }
}
```

### 8.2 Search for remaining `10.0.10.` references

Grep the codebase for `10.0.10.` to find remaining references:
- MicroVM guest configs referencing jotunheimr's NAS IP
- DNS configuration in alfheim's modules
- Prometheus/monitoring targets
- Any scripts or deployment tools

---

## IPv6 Considerations

- **VLAN 10 (vMGMT):** `fdc6:55f2:0a5e:a::1/64` — unchanged, now for networking gear
- **VLAN 11 (vINFRA):** `fdc6:55f2:0a5e:b::1/64` — new, auto-generated from `subnetId = 11`
- Host IPv6 via SLAAC from Router Advertisements — automatic
- The zone system handles IPv6 firewall rules identically to IPv4 (nftables `inet` family)

---

## Complete File Change List

| File | Phase | Changes |
|------|-------|---------|
| `modules/router6/default.nix` | 0, 1 | Add `zones` option, `baseRules` option, rename `trust` to `zone` (required), rewrite nftables generation to iterate zones, add zone assertions |
| `tests/modules/router6-firewall-zones.nix` | 0, 2 | New comprehensive multi-zone firewall test |
| `tests/lib/router6-firewall-snapshot.nix` | 0 | New snapshot test for nftables output stability |
| `tests/default.nix` | 0 | Register new tests |
| `hosts/yggdrasil/default.nix` | 2 | Add vINFRA VLAN, define `network` zone, override `management` zone with `forwardRules`, change vMGMT trust to "network", update DNS config, update DNS interception, update extraHosts, update MicroVM bridge rules, add NTP server |
| `hosts/yggdrasil/guests/alfheim/microvm.nix` | 3 | Change tap interface name and MAC |
| `hosts/yggdrasil/guests/alfheim/default.nix` | 3 | Update IP, gateway, MAC, extraHosts |
| `hosts/vanaheim/default.nix` | 3 | Change VLAN 10→11 in initrd network, update IP/gateway/DNS |
| `hosts/vanaheim/microvm.nix` | 3 | Change VLAN 10→11 in runtime network, update IP/gateway, add host firewall |
| `hosts/muspelheim/default.nix` | 3, 4 | Change VLAN 10→11, update IP/gateway/DNS, update NFS mount targets, add host firewall |
| `hosts/jotunheimr/default.nix` | 3 | Change VLAN 10→11, update IP/gateway/DNS, add host firewall |
| `hosts/jotunheimr/nas.nix` | 4 | Tighten NFS exports to per-IP, update subnet references |
| `lib/common/data/network.json` | 8 | Update IPs for alfheim, jotunheimr, muspelheim, vanaheim, yggdrasil |
| `lib/openwrt/default.nix` | 6 | Keep nftables package, change NTP servers to router IP, add host firewall script |

---

## Future Improvements (Out of Scope)

1. **Samba authentication hardening:** Uncomment `valid users` / `force user` on shares
3. **wg-vpn trust level:** Consider a "vpn" zone with different forwarding rules
4. **Monitoring/alerting:** Prometheus exporters on infra devices
5. **DoT/DoH blocking:** Block port 853 outbound from untrusted/IoT
6. **deploy-rs integration:** Full deploy-rs flake configuration with magic rollback
7. **Nix store signing:** Build host signs closures, infra devices verify signatures
