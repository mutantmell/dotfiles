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
vMGMT (VLAN 10) — zone: network
  IPv4: 10.0.10.0/24 — IPv6: fdc6:55f2:0a5e:a::/64
├── yggdrasil    10.0.10.1 / fdc6:55f2:0a5e:a::1   (router gateway)
└── APs/Switch   static IPs
    Devices can ONLY reach the router for NTP.
    No internet. No access to other VLANs.
    SSH only FROM the router TO the devices.

vINFRA (VLAN 11) — zone: management
  IPv4: 10.0.11.0/24 — IPv6: fdc6:55f2:0a5e:b::/64
├── yggdrasil    10.0.11.1  / fdc6:55f2:0a5e:b::1   (router gateway)
├── alfheim      10.0.11.2  / fdc6:55f2:0a5e:b::2   (DNS MicroVM on yggdrasil)
├── vanaheim     10.0.11.30 / fdc6:55f2:0a5e:b::1e  (VM host)
├── muspelheim   10.0.11.31 / fdc6:55f2:0a5e:b::1f  (VM host)
└── jotunheimr   10.0.11.32 / fdc6:55f2:0a5e:b::20  (NAS)
    Devices can communicate with each other (NFS, monitoring).
    Internet access for updates (filtered egress).
    SSH from router + admin workstation on vHOME.

IPv6 address scheme: static ULA assignments mirroring IPv4 last octet in hex.
All infra hosts get explicit static IPv6 (not SLAAC) for stable addressing.
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

## Phase 2: New `network` Zone and vINFRA VLAN

With the zone system in place, adding the `network` zone is just a configuration change.

### 2.1 Define `network` zone

**File:** `hosts/yggdrasil/default.nix` (alongside the other zone definitions)

```nix
router6.zones.network = {
  # Networking gear: NTP only, no internet, no lateral movement
  # APs and switches have static IPs — no DHCP needed
  icmpEcho = "enable";
  accessTo = [];
  inputRules = [
    { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
  ];
};
```

This automatically generates:
- Input: `iifname { "vMGMT.br0" } icmp type { echo-request, echo-reply } accept` (from icmpEcho)
- Input: `iifname { "vMGMT.br0" } icmpv6 type { echo-request, echo-reply } accept` (from icmpEcho)
- Input: `iifname { "vMGMT.br0" } udp dport 123 accept` (from inputRules)
- Forward: nothing (empty `accessTo`, no `forwardRules`)
- No hardcoded `networkInterfaces` selector needed

### 2.2 Management egress filtering via `forwardRules`

With the zone system, the vINFRA egress filtering that was previously planned as `extraForwardRules` with hardcoded interface names becomes a clean zone-level config:

```nix
router6.zones.management = {
  # Full router access, can reach all internal zones
  icmpEcho = "enable";
  accessTo = [ "management" "trusted" "untrusted" ];
  # Filtered internet access (not in accessTo — uses forwardRules instead)
  forwardRules = {
    external = [
      { udp.dport = 53; verdict = "accept";
        comment = "DNS recursive queries (Unbound on alfheim)"; }
      { tcp.dport = 53; verdict = "accept";
        comment = "DNS recursive queries (TCP fallback)"; }
      { tcp.dport = 80; verdict = "accept";
        comment = "HTTP for package mirrors"; }
      { tcp.dport = 443; verdict = "accept";
        comment = "HTTPS for updates (cache.nixos.org, github)"; }
      { udp.dport = 123; verdict = "accept";
        comment = "NTP to internet pools"; }
    ];
  };
  inputRules = [
    { verdict = "accept"; comment = "Full router service access"; }
  ];
};
```

Note: `"external"` is NOT in `accessTo` — instead, `forwardRules.external` provides filtered
access. The assertion from Phase 1.6 enforces this mutual exclusion. There is no trailing
`{ verdict = "drop"; }` — the forward chain's `policy drop` handles unmatched traffic, keeping
the rules declarative (only what's allowed, not what's denied).

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

Update alfheim's IP in DNS interception exclusions (IPv4):
```nix
# IPv4 DNS interception (in table ip nat)
{
  ip.saddr = { not = "10.0.11.2"; };
  ip.daddr = { not = [ "10.0.11.1" "10.0.11.2" ]; };
  udp.dport = 53;
  verdict = { dnat = "10.0.11.1:53"; };
  comment = "Intercept DNS bypass (UDP)";
}
{
  ip.saddr = { not = "10.0.11.2"; };
  ip.daddr = { not = [ "10.0.11.1" "10.0.11.2" ]; };
  tcp.dport = 53;
  verdict = { dnat = "10.0.11.1:53"; };
  comment = "Intercept DNS bypass (TCP)";
}
```

**IPv6 DNS interception** — add parallel rules to the `table ip6 nat` prerouting chain
(currently empty). These catch IPv6 DNS bypass attempts:
```nix
# IPv6 DNS interception (in table ip6 nat — currently empty, needs populating)
{
  ip6.saddr = { not = "fdc6:55f2:0a5e:b::2"; };
  ip6.daddr = { not = [ "fdc6:55f2:0a5e:b::1" "fdc6:55f2:0a5e:b::2" ]; };
  udp.dport = 53;
  verdict = { dnat = "[fdc6:55f2:0a5e:b::1]:53"; };
  comment = "Intercept IPv6 DNS bypass (UDP)";
}
{
  ip6.saddr = { not = "fdc6:55f2:0a5e:b::2"; };
  ip6.daddr = { not = [ "fdc6:55f2:0a5e:b::1" "fdc6:55f2:0a5e:b::2" ]; };
  tcp.dport = 53;
  verdict = { dnat = "[fdc6:55f2:0a5e:b::1]:53"; };
  comment = "Intercept IPv6 DNS bypass (TCP)";
}
```

Note: The router6 module's `table ip6 nat` prerouting chain is currently empty. Either add
a new `firewall.extraNat6Rules` option or populate the chain directly. The nft DSL may need
a small extension to support `ip6.saddr`/`ip6.daddr` if not already present.

kresd binds to all internal interfaces, so any of the router's IPs works as the DNAT target.
The main thing is updating the exclusion IPs so alfheim's traffic isn't redirected.

### 2.8 Update `/etc/hosts`

**File:** `hosts/yggdrasil/default.nix`

```nix
networking.extraHosts = ''
  10.0.11.1 yggdrasil
  10.0.11.1 yggdrasil.local
  fdc6:55f2:0a5e:b::1 yggdrasil yggdrasil.local
  10.0.11.2 alfheim
  10.0.11.2 alfheim.local
  fdc6:55f2:0a5e:b::2 alfheim alfheim.local
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

Update network configuration — assign static IPv6 alongside IPv4:
```nix
systemd.network.networks."20-tap" = {
  matchConfig.Type = "ether";
  matchConfig.MACAddress = "5E:11:AD:01:00:02";
  networkConfig = {
    Address = [ "10.0.11.2/24" "fdc6:55f2:0a5e:b::2/64" ];
    Gateway = "10.0.11.1";
    DNS = [ "127.0.0.1" "::1" ];
    IPv6AcceptRA = false;  # Static IPv6 now, disable SLAAC
    DHCP = "no";
  };
  routes = [{ Gateway = "fdc6:55f2:0a5e:b::1"; }];
};
```

Update `/etc/hosts`:
```nix
networking.extraHosts = ''
  10.0.11.1 yggdrasil.local
  fdc6:55f2:0a5e:b::1 yggdrasil.local
  10.0.20.30 gridr.local
  10.0.100.40 surtr.local
'';
```

**File:** `hosts/yggdrasil/guests/alfheim/modules/dns.nix` — **critical, DNS breaks if missed**

Update Adguard Home `allowed_clients` (add IPv6 addresses):
```nix
allowed_clients = [
  "127.0.0.1"
  "::1"
  "10.0.11.1"              # Yggdrasil (router) — changed from 10.0.10.1
  "fdc6:55f2:0a5e:b::1"   # Yggdrasil (router) IPv6
  "10.0.11.2"              # Self — changed from 10.0.10.2
  "fdc6:55f2:0a5e:b::2"   # Self IPv6
  "10.97.10.1"             # Router migration network
  "10.97.10.2"             # Self migration network
];
```

Update Unbound `local-data` records — add AAAA records for IPv6-first resolution,
update all infra hosts to 10.0.11.x:
```nix
local-data = [
  # Router
  ''"local. A 10.0.11.1"''
  ''"local. AAAA fdc6:55f2:0a5e:b::1"''
  ''"yggdrasil.local. A 10.0.11.1"''
  ''"yggdrasil.local. AAAA fdc6:55f2:0a5e:b::1"''

  # This microVM (DNS)
  ''"alfheim.local. A 10.0.11.2"''
  ''"alfheim.local. AAAA fdc6:55f2:0a5e:b::2"''

  # Auth server (Gridr on jotunheimr)
  ''"gridr.local. A 10.0.20.30"''

  # NAS
  ''"jotunheimr.local. A 10.0.11.32"''
  ''"jotunheimr.local. AAAA fdc6:55f2:0a5e:b::20"''

  # Media host
  ''"muspelheim.local. A 10.0.11.31"''
  ''"muspelheim.local. AAAA fdc6:55f2:0a5e:b::1f"''

  # Services in DMZ
  ''"surtr.local. A 10.0.100.40"''
  ''"bragi.local. A 10.0.100.50"''
  ''"njord.local. A 10.0.100.51"''
  ''"hrungnir.local. A 10.0.100.31"''

  # Home automation
  ''"nidavellir.local. A 10.1.20.50"''

  # MicroVMs on HOME network
  ''"skadi.local. A 10.0.20.40"''
  ''"ymir.local. A 10.0.20.41"''

  # VM host
  ''"vanaheim.local. A 10.0.11.30"''
  ''"vanaheim.local. AAAA fdc6:55f2:0a5e:b::1e"''
];
```

Note: AAAA records are only added for vINFRA hosts with known static IPv6. Other hosts
(DMZ, HOME, etc.) use SLAAC with privacy extensions — their IPv6 is unstable and not
suitable for static DNS records. AAAA records for those can be added later when they
get static assignments.

### 3.2 vanaheim (VM host)

**File:** `hosts/vanaheim/default.nix` — initrd network (for ZFS remote unlock)

Change VLAN 10 to VLAN 11, add static IPv6:
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
    networkConfig.IPv6AcceptRA = false;
    networkConfig.Address = [ "10.0.11.30/24" "fdc6:55f2:0a5e:b::1e/64" ];
    networkConfig.MulticastDNS = true;
    networkConfig.DNS = [ "10.0.11.1" "fdc6:55f2:0a5e:b::1" ];
    routes = [
      { Gateway = "10.0.11.1"; }
      { Gateway = "fdc6:55f2:0a5e:b::1"; }
    ];
  };
};
```

**File:** `hosts/vanaheim/microvm.nix` — runtime network

Same pattern: change `.10` to `.11`, add static IPv6 `fdc6:55f2:0a5e:b::1e/64`,
disable SLAAC (`IPv6AcceptRA = false`), add IPv6 gateway.

### 3.3 muspelheim (VM host)

**File:** `hosts/muspelheim/default.nix`

Same pattern as vanaheim: `eno1.10` → `eno1.11`, address `10.0.10.31/24` → `10.0.11.31/24`,
add static IPv6 `fdc6:55f2:0a5e:b::1f/64`, gateway/DNS `10.0.10.1` → `10.0.11.1` +
`fdc6:55f2:0a5e:b::1`, NFS mounts `10.0.10.32` → `10.0.11.32`, disable SLAAC.

### 3.4 jotunheimr (NAS)

**File:** `hosts/jotunheimr/default.nix`

Change VLAN 10 to VLAN 11, add static IPv6 `fdc6:55f2:0a5e:b::20/64`,
update addresses/gateway/DNS to 10.0.11.x + `fdc6:55f2:0a5e:b::1`, disable SLAAC.

---

## Phase 4: NFS/Storage Hardening

### 4.1 Tighten NFS exports

**File:** `hosts/jotunheimr/nas.nix`

Change subnet-wide exports to per-IP exports for VM hosts. Include both IPv4 and IPv6
addresses so NFS works over either protocol:

```nix
services.nfs.server = {
  enable = true;
  exports = ''
    /data/media 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::1e(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::1f(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)
    /data/data 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::1e(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::1f(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)
    /export/ro/media 10.0.11.0/24(ro) fdc6:55f2:0a5e:b::/64(ro) 10.0.20.0/24(ro)
    /export/rw/media 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::1e(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::1f(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)
    /export/ro/data 10.0.11.0/24(ro) fdc6:55f2:0a5e:b::/64(ro) 10.0.20.0/24(ro)
    /export/rw/data 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::1e(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::1f(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)
    /export/rw/backup 10.0.11.0/24(rw,sync,no_subtree_check,no_root_squash) fdc6:55f2:0a5e:b::/64(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check) 10.1.10.0/24(rw,sync,no_subtree_check,no_root_squash) 10.1.20.0/24(rw,sync,no_subtree_check,no_root_squash)
  '';
};
```

### 4.2 Update NFS mount targets

**File:** `hosts/muspelheim/default.nix`

Use IPv6 addresses for NFS mounts (IPv6-first), with IPv4 as fallback:
```nix
fileSystems."/mnt/data".device = "[fdc6:55f2:0a5e:b::20]:/data/data";
fileSystems."/mnt/media".device = "[fdc6:55f2:0a5e:b::20]:/data/media/";
```

---

## Phase 5: Host-Based Firewalls

### 5.1 jotunheimr (NAS)

Replace blanket open ports with source-restricted nftables rules. NixOS 23.11+ defaults to
nftables, so we use `networking.firewall.extraInputRules` (nftables syntax). All rules
specify both IPv4 and IPv6 sources:

```nix
networking.firewall = {
  enable = true;
  # Remove blanket allowedTCPPorts/allowedUDPPorts — replaced by source-restricted rules
  extraInputRules = ''
    # NFS from VM hosts only (IPv4 + IPv6)
    ip saddr { 10.0.11.30, 10.0.11.31 } tcp dport 2049 accept
    ip6 saddr { fdc6:55f2:0a5e:b::1e, fdc6:55f2:0a5e:b::1f } tcp dport 2049 accept
    ip saddr 10.0.20.0/24 tcp dport 2049 accept

    # SMB from vHOME only (IPv4 — SMB over IPv6 can be added later)
    ip saddr 10.0.20.0/24 tcp dport { 139, 445 } accept
    ip saddr 10.0.20.0/24 udp dport { 137, 138 } accept

    # WSDD from vHOME only
    ip saddr 10.0.20.0/24 tcp dport 5357 accept
    ip saddr 10.0.20.0/24 udp dport 3702 accept

    # SSH from router and admin workstation (IPv4 + IPv6)
    ip saddr { 10.0.11.1, 10.0.20.0/24 } tcp dport 22 accept
    ip6 saddr { fdc6:55f2:0a5e:b::1, fdc6:55f2:0a5e:14::/64 } tcp dport 22 accept
    tcp dport 22 drop
  '';
};
```

### 5.2 vanaheim / muspelheim (VM hosts)

SSH only from router and admin workstation (dual-stack):
```nix
networking.firewall = {
  enable = true;
  extraInputRules = ''
    ip saddr { 10.0.11.1, 10.0.20.0/24 } tcp dport 22 accept
    ip6 saddr { fdc6:55f2:0a5e:b::1, fdc6:55f2:0a5e:14::/64 } tcp dport 22 accept
    tcp dport 22 drop
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

Add nftables rules to AP images restricting SSH to router only (dual-stack):
```sh
nft add table inet filter
nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'
nft add rule inet filter input ct state established,related accept
nft add rule inet filter input iifname "lo" accept
nft add rule inet filter input icmp type echo-request accept
nft add rule inet filter input icmpv6 type '{ echo-request, echo-reply }' accept
nft add rule inet filter input icmpv6 type '{ nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert }' accept
nft add rule inet filter input ip saddr 10.0.10.1 tcp dport 22 accept
nft add rule inet filter input ip6 saddr fdc6:55f2:0a5e:a::1 tcp dport 22 accept
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
    "alfheim": { "ipv4": "10.0.11.2", "ipv6": "fdc6:55f2:0a5e:b::2" },
    "jotunheimr": { "ipv4": "10.0.11.32", "ipv6": "fdc6:55f2:0a5e:b::20" },
    "muspelheim": { "ipv4": "10.0.11.31", "ipv6": "fdc6:55f2:0a5e:b::1f" },
    "vanaheim": { "ipv4": "10.0.11.30", "ipv6": "fdc6:55f2:0a5e:b::1e" },
    "yggdrasil": { "ipv4": "10.0.11.1", "ipv6": "fdc6:55f2:0a5e:b::1" }
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

### Addressing

- **VLAN 10 (vMGMT):** `fdc6:55f2:0a5e:a::/64` — unchanged, now for networking gear
- **VLAN 11 (vINFRA):** `fdc6:55f2:0a5e:b::/64` — new, auto-generated from `subnetId = 11`

### Static IPv6 for infra hosts

All vINFRA hosts get **static ULA addresses** (not SLAAC) so they can be referenced in
firewall rules, NFS exports, DNS records, and service configs. The addressing scheme mirrors
the IPv4 last octet in hex:

| Host | IPv4 | IPv6 |
|------|------|------|
| yggdrasil | 10.0.11.1 | `fdc6:55f2:0a5e:b::1` |
| alfheim | 10.0.11.2 | `fdc6:55f2:0a5e:b::2` |
| vanaheim | 10.0.11.30 | `fdc6:55f2:0a5e:b::1e` |
| muspelheim | 10.0.11.31 | `fdc6:55f2:0a5e:b::1f` |
| jotunheimr | 10.0.11.32 | `fdc6:55f2:0a5e:b::20` |

Previously these hosts used SLAAC with privacy extensions (`IPv6PrivacyExtensions = "kernel"`),
producing unstable addresses. Switching to static IPv6 with `IPv6AcceptRA = false` gives
predictable addresses suitable for ACLs, DNS AAAA records, and NFS exports.

### Dual-stack coverage

IPv6 addresses are included in:
- **DNS** (AAAA records in Unbound for all infra hosts)
- **DNS interception** (IPv6 DNAT rules in `table ip6 nat`)
- **NFS exports** (IPv6 per-host ACLs alongside IPv4)
- **NFS mounts** (IPv6-first mount targets)
- **Host firewalls** (dual-stack `ip saddr` + `ip6 saddr` rules)
- **AP firewalls** (IPv6 SSH allow from router)
- **Adguard Home** (IPv6 `allowed_clients`)
- **extraHosts** (IPv6 entries on router and alfheim)
- **network.json** (IPv6 field added)

### Zone-level firewall

The zone system uses nftables `inet` family, so zone rules (`accessTo`, `forwardRules`,
`inputRules`, `icmpEcho`) apply to both IPv4 and IPv6 automatically. No per-zone IPv6
duplication is needed — `iifname`/`oifname` matching is protocol-agnostic.

### Router Advertisements

The router still sends RAs on vINFRA for link-layer discovery, but infra hosts ignore them
for address configuration (`IPv6AcceptRA = false`). Non-infra VLANs (vHOME, vGUEST, etc.)
continue to use SLAAC as before.

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
| `hosts/yggdrasil/guests/alfheim/modules/dns.nix` | 3 | Update allowed_clients IPs, Unbound local-data records (7 IPs) |
| `hosts/vanaheim/default.nix` | 3 | Change VLAN 10→11 in initrd network, update IP/gateway/DNS |
| `hosts/vanaheim/microvm.nix` | 3 | Change VLAN 10→11 in runtime network, update IP/gateway, add host firewall |
| `hosts/muspelheim/default.nix` | 3, 4 | Change VLAN 10→11, update IP/gateway/DNS, update NFS mount targets, add host firewall |
| `hosts/jotunheimr/default.nix` | 3 | Change VLAN 10→11, update IP/gateway/DNS, add host firewall |
| `hosts/jotunheimr/nas.nix` | 4 | Tighten NFS exports to per-IP, update subnet references |
| `lib/common/data/network.json` | 8 | Update IPs for alfheim, jotunheimr, muspelheim, vanaheim, yggdrasil |
| `lib/openwrt/default.nix` | 6 | Keep nftables package, change NTP servers to router IP, add host firewall script |

---

## Phase 9: Dual-Address Migration (10.0.x.x → 10.97.x.x)

### Background

The `10.0.0.0/16` range frequently overlaps with other private networks (home routers,
corporate LANs, VPN providers). This causes routing conflicts when accessing internal
services via WireGuard from networks that also use `10.0.x.x`. The target range
`10.97.0.0/16` is far less common and avoids these collisions.

The migration has already partially started:
- alfheim already has `10.97.10.2/24` as a secondary address
- Adguard's `allowed_clients` includes `10.97.10.1` and `10.97.10.2`
- gridr's auth config already includes `10.97.0.0/16` in its allowed IP list

### Address mapping

The mapping is `10.0.X.Y` → `10.97.X.Y` — identical third and fourth octets. This applies
to all VLANs on the router and all host addresses:

| VLAN | Current | Migration |
|------|---------|-----------|
| vMGMT | 10.0.10.0/24 | 10.97.10.0/24 |
| vINFRA (new) | 10.0.11.0/24 | 10.97.11.0/24 |
| vHOME | 10.0.20.0/24 | 10.97.20.0/24 |
| vGUEST | 10.0.30.0/24 | 10.97.30.0/24 |
| vADU | 10.0.31.0/24 | 10.97.31.0/24 |
| vIOT | 10.0.40.0/24 | 10.97.40.0/24 |
| vGAME | 10.0.41.0/24 | 10.97.41.0/24 |
| vDMZ | 10.0.100.0/24 | 10.97.100.0/24 |

WireGuard tunnels (`10.100.x.x`) are a separate /16 and don't conflict with typical
home networks. They can be migrated later if needed.

### 9.1 Dual addresses on router VLANs

**File:** `hosts/yggdrasil/default.nix` — every VLAN in topology gets a secondary address

For each VLAN, add the `10.97.x.x` address alongside the `10.0.x.x` address:
```nix
# Example: vINFRA
"vINFRA.br0" = {
  tag = 11;
  network = {
    type = "static";
    addresses = [ "10.0.11.1/24" "10.97.11.1/24" ];  # Dual addresses
    subnetId = 11;
    zone = "management";
    dhcp.enable = true;
    dhcp6.enable = true;
  };
};

# Same pattern for vMGMT, vHOME, vGUEST, vADU, vIOT, vGAME, vDMZ
```

The router6 module should handle multiple addresses per interface already (systemd-networkd
supports it natively). DHCP pools for the `10.97.x.x` range need to be configured — either
via a second Kea subnet or by migrating the pool range.

### 9.2 Dual addresses on infra hosts

Each infra host's systemd-networkd config gets a secondary address. Example for vanaheim:
```nix
networkConfig.Address = [
  "10.0.11.30/24" "10.97.11.30/24"
  "fdc6:55f2:0a5e:b::1e/64"
];
```

All infra hosts:

| Host | Primary | Secondary | IPv6 |
|------|---------|-----------|------|
| alfheim | 10.0.11.2/24 | 10.97.11.2/24 | fdc6:55f2:0a5e:b::2/64 |
| vanaheim | 10.0.11.30/24 | 10.97.11.30/24 | fdc6:55f2:0a5e:b::1e/64 |
| muspelheim | 10.0.11.31/24 | 10.97.11.31/24 | fdc6:55f2:0a5e:b::1f/64 |
| jotunheimr | 10.0.11.32/24 | 10.97.11.32/24 | fdc6:55f2:0a5e:b::20/64 |

Alfheim already has dual addresses (`10.0.10.2/24` + `10.97.10.2/24`), so just update
the octets for the VLAN 11 move.

### 9.3 Dual addresses on guest VMs (non-infra)

Guest VMs on other VLANs also need dual addresses if they have static IPs:

| Guest | VLAN | Primary | Secondary |
|-------|------|---------|-----------|
| gridr | vHOME (20) | 10.0.20.30/24 | 10.97.20.30/24 |
| skadi | vHOME (20) | 10.0.20.40/24 | 10.97.20.40/24 |
| ymir | vHOME (20) | 10.0.20.41/24 | 10.97.20.41/24 |
| surtr | vDMZ (100) | 10.0.100.40/24 | 10.97.100.40/24 |
| bragi | vDMZ (100) | 10.0.100.50/24 | 10.97.100.50/24 |
| njord | vDMZ (100) | 10.0.100.51/24 | 10.97.100.51/24 |
| hrungnir | vDMZ (100) | 10.0.100.31/24 | 10.97.100.31/24 |

### 9.4 DNS dual records

**File:** `hosts/yggdrasil/guests/alfheim/modules/dns.nix`

Add A records for both ranges in Unbound's `local-data`. Clients resolving `.local`
names will get both IPs and prefer whichever route works:
```nix
# Each host gets two A records
''"yggdrasil.local. A 10.0.11.1"''
''"yggdrasil.local. A 10.97.11.1"''
''"yggdrasil.local. AAAA fdc6:55f2:0a5e:b::1"''
# ... same pattern for all hosts
```

Adguard `allowed_clients` needs both ranges for the router and self:
```nix
allowed_clients = [
  "127.0.0.1" "::1"
  "10.0.11.1" "10.97.11.1" "fdc6:55f2:0a5e:b::1"    # Router
  "10.0.11.2" "10.97.11.2" "fdc6:55f2:0a5e:b::2"    # Self
  "10.97.10.1" "10.97.10.2"                            # Migration network (keep)
];
```

### 9.5 DNS interception dual rules

**File:** `hosts/yggdrasil/default.nix` — `firewall.extraNatRules`

DNS interception exclusions need to cover both alfheim addresses:
```nix
{
  ip.saddr = { not = [ "10.0.11.2" "10.97.11.2" ]; };
  ip.daddr = { not = [ "10.0.11.1" "10.0.11.2" "10.97.11.1" "10.97.11.2" ]; };
  udp.dport = 53;
  verdict = { dnat = "10.97.11.1:53"; };  # DNAT target can use new range
  comment = "Intercept DNS bypass (UDP)";
}
```

### 9.6 NFS exports dual ranges

**File:** `hosts/jotunheimr/nas.nix`

NFS exports need both subnets (NFS matches source IP, so both ranges must be listed):
```nix
/data/media 10.0.11.30(...) 10.97.11.30(...) fdc6:55f2:0a5e:b::1e(...) 10.0.11.31(...) 10.97.11.31(...) fdc6:55f2:0a5e:b::1f(...) 10.0.20.0/24(...) 10.97.20.0/24(...)
```

### 9.7 Host firewalls dual ranges

**Files:** Phase 5 host configs

All `ip saddr` rules need both ranges:
```nix
extraInputRules = ''
  # NFS from VM hosts (10.0.x + 10.97.x + IPv6)
  ip saddr { 10.0.11.30, 10.0.11.31, 10.97.11.30, 10.97.11.31 } tcp dport 2049 accept
  ip6 saddr { fdc6:55f2:0a5e:b::1e, fdc6:55f2:0a5e:b::1f } tcp dport 2049 accept

  # SSH from router + admin (10.0.x + 10.97.x + IPv6)
  ip saddr { 10.0.11.1, 10.97.11.1, 10.0.20.0/24, 10.97.20.0/24 } tcp dport 22 accept
  ip6 saddr { fdc6:55f2:0a5e:b::1, fdc6:55f2:0a5e:14::/64 } tcp dport 22 accept
  tcp dport 22 drop
'';
```

### 9.8 extraHosts dual entries

**File:** `hosts/yggdrasil/default.nix`
```nix
networking.extraHosts = ''
  10.0.11.1 yggdrasil yggdrasil.local
  10.97.11.1 yggdrasil yggdrasil.local
  fdc6:55f2:0a5e:b::1 yggdrasil yggdrasil.local
  10.0.11.2 alfheim alfheim.local
  10.97.11.2 alfheim alfheim.local
  fdc6:55f2:0a5e:b::2 alfheim alfheim.local
  ...
'';
```

### 9.9 WireGuard peer AllowedIPs

**File:** `hosts/yggdrasil/default.nix` — wg-vpn peers

The WireGuard VPN peers need to route both ranges to the tunnel. Update the
WireGuard peer configs on client devices to include `10.97.0.0/16` in AllowedIPs
(alongside the existing `10.0.0.0/16`). The server-side `allowedIPs` for each peer
doesn't change (it specifies the peer's tunnel IP, not routed subnets).

### 9.10 DHCP pools

The Kea DHCP4 server needs dual pools — one for each range — on every VLAN with DHCP
enabled. DHCP clients will get addresses from whichever pool responds first, but in
practice we want clients on the new range. This can be done by:
- Adding a second Kea subnet for each VLAN's `10.97.x.x` range
- Setting a shorter lease time on the `10.0.x.x` pools to encourage migration
- Or simply switching the DHCP pool to `10.97.x.x` only (clients on the old range
  keep their static/existing leases until renewal)

### 9.11 network.json

**File:** `lib/common/data/network.json`

Add both addresses:
```json
{
  "hosts": {
    "alfheim": { "ipv4": "10.97.11.2", "ipv4_legacy": "10.0.11.2", "ipv6": "fdc6:55f2:0a5e:b::2" },
    ...
  }
}
```

---

## Appendix: 10.0.x.x Removal Checklist

Once all clients and services are confirmed working on `10.97.x.x`, remove the legacy
`10.0.x.x` addresses. This is a mechanical cleanup:

### Router (yggdrasil)
- [ ] Remove `10.0.x.1/24` secondary addresses from all VLAN topology entries
- [ ] Remove `10.0.x.x` entries from `networking.extraHosts`
- [ ] Remove `10.0.x.x` exclusions from DNS interception rules (`extraNatRules`)
- [ ] Update DNAT targets to use only `10.97.x.x`
- [ ] Update `dns.upstream` to `10.97.11.2` only
- [ ] Remove `10.0.x.x` from chrony `allow` directives

### DNS (alfheim)
- [ ] Remove `10.0.x.x` A records from Unbound `local-data` (keep only `10.97.x.x` + AAAA)
- [ ] Remove `10.0.x.x` entries from Adguard `allowed_clients`
- [ ] Remove `10.0.x.x` from `networking.extraHosts`
- [ ] Remove `10.0.11.2/24` from alfheim's interface `Address` list
- [ ] Remove legacy migration entries (`10.97.10.1`, `10.97.10.2`) once VLAN 10→11 move is done

### Infra hosts (vanaheim, muspelheim, jotunheimr)
- [ ] Remove `10.0.x.x/24` from each host's `Address` list
- [ ] Update `Gateway` to `10.97.x.1` only
- [ ] Update `DNS` to `10.97.x.1` only
- [ ] Update NFS mount targets to `10.97.x.x` only (muspelheim)

### NAS (jotunheimr)
- [ ] Remove `10.0.x.x` entries from NFS exports (keep `10.97.x.x` + IPv6)
- [ ] Remove `10.0.x.x` from host firewall `ip saddr` rules

### Guest VMs
- [ ] Remove `10.0.x.x/24` from each guest's `Address` list
- [ ] Update `Gateway` and `DNS` to `10.97.x.x`
- [ ] Update `networking.extraHosts` entries

### Auth (gridr)
- [ ] Remove `10.0.0.0/16` from Keycloak allowed IP list (keep `10.97.0.0/16`)
- [ ] Remove `10.1.0.0/16` if mesh network also migrated

### OpenWRT APs
- [ ] Update static IPs from `10.0.10.x` to `10.97.10.x`
- [ ] Update NTP server to `10.97.10.1`
- [ ] Update AP firewall SSH allow from `10.0.10.1` → `10.97.10.1`

### network.json
- [ ] Remove `ipv4_legacy` field, rename `ipv4` values to `10.97.x.x` only

### WireGuard
- [ ] Remove `10.0.0.0/16` from client AllowedIPs (keep `10.97.0.0/16`)
- [ ] Consider migrating tunnel addresses (`10.100.x.x`) if needed

### Tests
- [ ] Update test IP addresses in `tests/modules/router6-*.nix` files
  (these use `10.0.x.x` as test values — can be updated independently)

### Verification
- [ ] Confirm all services respond on `10.97.x.x`
- [ ] Confirm WireGuard VPN works from external networks without conflicts
- [ ] Confirm DNS resolution returns only `10.97.x.x` A records
- [ ] Confirm NFS mounts use `10.97.x.x` or IPv6
- [ ] Run `grep -r '10\.0\.' hosts/ modules/ lib/` and verify no stale references remain

---

## Future Improvements (Out of Scope)

1. **Samba authentication hardening:** Uncomment `valid users` / `force user` on shares
3. **wg-vpn trust level:** Consider a "vpn" zone with different forwarding rules
4. **Monitoring/alerting:** Prometheus exporters on infra devices
5. **DoT/DoH blocking:** Block port 853 outbound from untrusted/IoT
6. **deploy-rs integration:** Full deploy-rs flake configuration with magic rollback
7. **Nix store signing:** Build host signs closures, infra devices verify signatures
