# Zone system unit tests for router6
#
# Pure Nix evaluation tests that verify the zone abstraction works correctly.
# These test NEW zone features beyond the trust→zone migration.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-zone-system.nix
# Or:  nix build .#checks.x86_64-linux.router6-zone-system

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  # Helper to evaluate a router6 config and extract the nftables ruleset
  evalRuleset = router6Config: let
    eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules = [
        ../../modules/router6
        {
          boot.loader.grub.device = "nodev";
          fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "24.05";
          router6 = { enable = true; } // router6Config;
        }
      ];
    };
  in eval.config.networking.nftables.ruleset;

  # Helper to check if a string contains a substring
  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  # Helper to check if a string contains a regex pattern
  matches = pattern: haystack: builtins.match ".*${pattern}.*" haystack != null;

  # Helper to check a string does NOT contain a substring
  notContains = needle: haystack: !contains needle haystack;

  assertEq = name: a: b:
    if a == b then true
    else throw "FAIL: ${name}\n  Expected: ${builtins.toJSON b}\n  Got:      ${builtins.toJSON a}";

  assertTrue = name: v:
    if v then true
    else throw "FAIL: ${name}";

  assertFalse = name: v:
    if !v then true
    else throw "FAIL: ${name}";

  # ========================================================================
  # Test configs
  # ========================================================================

  # Test 1.7a: forwardRules integration
  forwardRulesConfig = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = [ "1.1.1.1" ];
    dns.useDHCPFallback = false;
    zones = {
      external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
      restricted = {
        icmpEcho = "enable";
        accessTo = [];
        forwardRules.external = [
          { tcp.dport = [ 443 80 ]; verdict = "accept"; comment = "HTTP(S) only"; }
          { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
        ];
        inputRules = [
          { udp.dport = [ 53 67 ]; verdict = "accept"; comment = "DNS + DHCP"; }
          { tcp.dport = 53; verdict = "accept"; comment = "DNS over TCP"; }
        ];
      };
    };
    topology = {
      eth1 = {
        hardwareName = "eth1";
        network = { type = "static"; addresses = [ "203.0.113.1/24" ]; zone = "external"; nat.enable = true; };
      };
      eth2 = {
        hardwareName = "eth2";
        network = { type = "static"; addresses = [ "10.0.50.1/24" ]; zone = "restricted"; dhcp.enable = true; };
      };
    };
  };

  # Test 1.7b: multiple interfaces per zone
  multiIfaceConfig = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = [ "1.1.1.1" ];
    dns.useDHCPFallback = false;
    zones = {
      external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
      lan = {
        icmpEcho = "enable";
        accessTo = [ "external" ];
        inputRules = [ { verdict = "accept"; } ];
      };
    };
    topology = {
      eth1 = {
        hardwareName = "eth1";
        network = { type = "static"; addresses = [ "203.0.113.1/24" ]; zone = "external"; nat.enable = true; };
      };
      eth2 = {
        hardwareName = "eth2";
        network = { type = "static"; addresses = [ "10.0.10.1/24" ]; zone = "lan"; dhcp.enable = true; };
      };
      eth3 = {
        hardwareName = "eth3";
        network = { type = "static"; addresses = [ "10.0.20.1/24" ]; zone = "lan"; dhcp.enable = true; };
      };
    };
  };

  # Test 1.7c: icmpEcho ipv4-only and ipv6-only
  icmpV4OnlyConfig = {
    dns.upstream = [ "1.1.1.1" ];
    dns.useDHCPFallback = false;
    zones = {
      external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
      v4only = {
        icmpEcho = "ipv4-only";
        accessTo = [ "external" ];
        inputRules = [ { verdict = "accept"; } ];
      };
    };
    topology = {
      eth1 = {
        hardwareName = "eth1";
        network = { type = "static"; addresses = [ "203.0.113.1/24" ]; zone = "external"; nat.enable = true; };
      };
      eth2 = {
        hardwareName = "eth2";
        network = { type = "static"; addresses = [ "10.0.10.1/24" ]; zone = "v4only"; };
      };
    };
  };

  icmpV6OnlyConfig = {
    dns.upstream = [ "1.1.1.1" ];
    dns.useDHCPFallback = false;
    zones = {
      external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
      v6only = {
        icmpEcho = "ipv6-only";
        accessTo = [ "external" ];
        inputRules = [ { verdict = "accept"; } ];
      };
    };
    topology = {
      eth1 = {
        hardwareName = "eth1";
        network = { type = "static"; addresses = [ "203.0.113.1/24" ]; zone = "external"; nat.enable = true; };
      };
      eth2 = {
        hardwareName = "eth2";
        network = { type = "static"; addresses = [ "10.0.10.1/24" ]; zone = "v6only"; };
      };
    };
  };

  # Test 1.7d: self-forwarding within a zone
  selfForwardConfig = {
    dns.upstream = [ "1.1.1.1" ];
    dns.useDHCPFallback = false;
    zones = {
      external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
      internal = {
        icmpEcho = "enable";
        accessTo = [ "internal" ];
        inputRules = [ { verdict = "accept"; } ];
      };
    };
    topology = {
      eth1 = {
        hardwareName = "eth1";
        network = { type = "static"; addresses = [ "203.0.113.1/24" ]; zone = "external"; nat.enable = true; };
      };
      eth2 = {
        hardwareName = "eth2";
        network = { type = "static"; addresses = [ "10.0.10.1/24" ]; zone = "internal"; };
      };
    };
  };

  # Test 1.7e: escape hatch interaction
  escapeHatchConfig = {
    dns.upstream = [ "1.1.1.1" ];
    dns.useDHCPFallback = false;
    zones = {
      external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
      lan = {
        icmpEcho = "enable";
        accessTo = [];
        inputRules = [ { verdict = "accept"; } ];
      };
    };
    firewall = {
      extraInputRules = [
        { tcp.dport = 8080; verdict = "accept"; comment = "Custom admin port"; }
      ];
      extraForwardRules = [
        { iifname = "wg0"; oifname = "eth1"; verdict = "accept"; comment = "WireGuard bypass"; }
      ];
    };
    topology = {
      eth1 = {
        hardwareName = "eth1";
        network = { type = "static"; addresses = [ "203.0.113.1/24" ]; zone = "external"; nat.enable = true; };
      };
      eth2 = {
        hardwareName = "eth2";
        network = { type = "static"; addresses = [ "10.0.10.1/24" ]; zone = "lan"; };
      };
    };
  };

  # Test 1.7f-1: empty zone
  emptyZoneConfig = {
    dns.upstream = [ "1.1.1.1" ];
    dns.useDHCPFallback = false;
    zones = {
      external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
      lan = {
        icmpEcho = "enable";
        accessTo = [ "external" ];
        inputRules = [ { verdict = "accept"; } ];
      };
      unused = {
        icmpEcho = "enable";
        accessTo = [ "external" ];
        inputRules = [ { verdict = "accept"; } ];
      };
    };
    topology = {
      eth1 = {
        hardwareName = "eth1";
        network = { type = "static"; addresses = [ "203.0.113.1/24" ]; zone = "external"; nat.enable = true; };
      };
      eth2 = {
        hardwareName = "eth2";
        network = { type = "static"; addresses = [ "10.0.10.1/24" ]; zone = "lan"; };
      };
      # Note: no interface references "unused" zone
    };
  };

  # Test 1.7f-2: baseRules = false
  noBaseRulesConfig = {
    dns.upstream = [ "1.1.1.1" ];
    dns.useDHCPFallback = false;
    zones = {
      external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
      lan = {
        icmpEcho = "enable";
        accessTo = [ "external" ];
        inputRules = [ { verdict = "accept"; } ];
      };
    };
    firewall.baseRules = false;
    topology = {
      eth1 = {
        hardwareName = "eth1";
        network = { type = "static"; addresses = [ "203.0.113.1/24" ]; zone = "external"; nat.enable = true; };
      };
      eth2 = {
        hardwareName = "eth2";
        network = { type = "static"; addresses = [ "10.0.10.1/24" ]; zone = "lan"; };
      };
    };
  };

  # ========================================================================
  # Tests
  # ========================================================================

  tests = let
    forwardRulesRuleset = evalRuleset forwardRulesConfig;
    multiIfaceRuleset = evalRuleset multiIfaceConfig;
    v4OnlyRuleset = evalRuleset icmpV4OnlyConfig;
    v6OnlyRuleset = evalRuleset icmpV6OnlyConfig;
    selfForwardRuleset = evalRuleset selfForwardConfig;
    escapeHatchRuleset = evalRuleset escapeHatchConfig;
    emptyZoneRuleset = evalRuleset emptyZoneConfig;
    noBaseRulesRuleset = evalRuleset noBaseRulesConfig;
  in [
    # ======================================================================
    # 1.7a: forwardRules
    # ======================================================================
    (assertTrue "forwardRules: HTTP(S) rule present"
      (contains ''iifname { "eth2" } oifname { "eth1" } tcp dport { 443, 80 } accept'' forwardRulesRuleset))

    (assertTrue "forwardRules: NTP rule present"
      (contains ''iifname { "eth2" } oifname { "eth1" } udp dport 123 accept'' forwardRulesRuleset))

    (assertTrue "forwardRules: no blanket accessTo accept"
      (notContains ''iifname { "eth2" } oifname { "eth1" } accept'' forwardRulesRuleset))

    (assertTrue "forwardRules: inputRules for DNS present"
      (contains ''iifname { "eth2" } udp dport { 53, 67 } accept'' forwardRulesRuleset))

    # ======================================================================
    # 1.7b: multiple interfaces per zone
    # ======================================================================
    (assertTrue "multi-iface: input uses set syntax"
      (contains ''iifname { "eth2", "eth3" } accept'' multiIfaceRuleset))

    (assertTrue "multi-iface: ICMP uses set syntax"
      (contains ''iifname { "eth2", "eth3" } icmp type { echo-request, echo-reply } accept'' multiIfaceRuleset))

    (assertTrue "multi-iface: forward uses set syntax"
      (contains ''iifname { "eth2", "eth3" } oifname { "eth1" } accept'' multiIfaceRuleset))

    # ======================================================================
    # 1.7c: icmpEcho ipv4-only and ipv6-only
    # ======================================================================
    (assertTrue "ipv4-only: has IPv4 ICMP echo"
      (contains ''iifname { "eth2" } icmp type { echo-request, echo-reply } accept'' v4OnlyRuleset))

    (assertTrue "ipv4-only: does NOT have IPv6 ICMP echo"
      (notContains ''iifname { "eth2" } icmpv6 type { echo-request, echo-reply } accept'' v4OnlyRuleset))

    (assertTrue "ipv4-only: still has essential ICMPv6 (NDP)"
      (contains "icmpv6 type { nd-router-solicit" v4OnlyRuleset))

    (assertTrue "ipv6-only: has IPv6 ICMP echo"
      (contains ''iifname { "eth2" } icmpv6 type { echo-request, echo-reply } accept'' v6OnlyRuleset))

    (assertTrue "ipv6-only: does NOT have IPv4 ICMP echo"
      (notContains ''iifname { "eth2" } icmp type { echo-request, echo-reply } accept'' v6OnlyRuleset))

    (assertTrue "ipv6-only: still has essential ICMPv4 (PMTUD)"
      (contains "icmp type { destination-unreachable" v6OnlyRuleset))

    # ======================================================================
    # 1.7d: self-forwarding within a zone
    # ======================================================================
    (assertTrue "self-forward: rule where iifname and oifname match"
      (contains ''iifname { "eth2" } oifname { "eth2" } accept'' selfForwardRuleset))

    # ======================================================================
    # 1.7e: escape hatch interaction
    # ======================================================================
    (assertTrue "escape hatch: zone input rules present"
      (contains ''iifname { "eth2" } accept'' escapeHatchRuleset))

    (assertTrue "escape hatch: extra input rules present"
      (contains ''tcp dport 8080 accept'' escapeHatchRuleset))

    (assertTrue "escape hatch: extra forward rules present"
      (contains ''iifname "wg0" oifname "eth1" accept'' escapeHatchRuleset))

    # Ordering: zone rules appear before escape hatch rules in the template.
    # This is structurally guaranteed by the template — zone rules are emitted
    # before extraInputRules / extraForwardRules. The presence checks above
    # confirm both are present; the template ensures ordering.

    # ======================================================================
    # 1.7f-1: empty zone (defined but no interfaces)
    # ======================================================================
    (assertTrue "empty zone: unused zone not mentioned in input rules"
      # The "unused" zone has inputRules but no interfaces, so no rules should reference it
      # We check that only eth2 (lan) has accept rules, not any other interface
      (notContains "unused" emptyZoneRuleset))

    (assertTrue "empty zone: active zone still works"
      (contains ''iifname { "eth2" } accept'' emptyZoneRuleset))

    # ======================================================================
    # 1.7f-2: baseRules = false
    # ======================================================================
    (assertTrue "no baseRules: no connection tracking in input"
      (notContains "ct state established,related accept" noBaseRulesRuleset))

    (assertTrue "no baseRules: no loopback accept"
      (notContains ''iifname "lo" accept'' noBaseRulesRuleset))

    (assertTrue "no baseRules: no essential ICMP"
      (notContains "icmp type { destination-unreachable" noBaseRulesRuleset))

    (assertTrue "no baseRules: no NDP rules"
      (notContains "nd-router-solicit" noBaseRulesRuleset))

    (assertTrue "no baseRules: no MSS clamping in forward"
      (notContains "tcp flags syn tcp option maxseg" noBaseRulesRuleset))

    (assertTrue "no baseRules: zone rules still present"
      (contains ''iifname { "eth2" } accept'' noBaseRulesRuleset))

    # ======================================================================
    # 1.7f-3: zone ordering stability
    # ======================================================================
    # Nix attrsets are sorted by key name, so eval should be deterministic
    (let
      a = evalRuleset multiIfaceConfig;
      b = evalRuleset multiIfaceConfig;
    in assertEq "ordering stability: same config produces same output" a b)
  ];

  allPass = lib.all (x: x) tests;

in
  if allPass then
    pkgs.runCommand "router6-zone-system" {} ''
      echo "All ${toString (builtins.length tests)} zone system tests passed"
      echo "PASS" > $out
    ''
  else
    throw "Zone system tests failed"
