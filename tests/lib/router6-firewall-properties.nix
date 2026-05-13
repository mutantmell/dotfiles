# Firewall property tests for router6
#
# Pure Nix evaluation tests that verify firewall properties:
# DHCPv6 client rules, NAT/masquerade, NDP base rules, PD-related behavior.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-firewall-properties.nix
# Or:  nix build .#checks.x86_64-linux.router6-firewall-properties
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  # Helper to evaluate a router6 config and extract the nftables ruleset
  evalRuleset = router6Config: let
    eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules = [
        ../../modules/router6
        {
          boot.loader.grub.device = "nodev";
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "25.11";
          router6 = {enable = true;} // router6Config;
        }
      ];
    };
  in
    eval.config.networking.nftables.ruleset;

  # Helper to check if a string contains a substring
  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  # Helper to check a string does NOT contain a substring
  notContains = needle: haystack: !contains needle haystack;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  # ========================================================================
  # Test configs
  # ========================================================================

  # Config A: DHCP WAN with PD + static LAN with dhcp6 (RA server)
  dhcpWanWithPD = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [{verdict = "accept";}];
      };
    };
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
          ipv6PrefixDelegation = {
            enable = true;
            prefixLength = 48;
          };
        };
      };
      lan = {
        hardwareName = "eth1";
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
          pdSubnetId = "1";
          dhcp6 = {
            enable = true;
            dnsAddress = "fdc6:55f2:0a5e:1::1";
          };
        };
      };
    };
  };

  # Config B: Static WAN (no DHCP, no PD)
  staticWan = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [{verdict = "accept";}];
      };
    };
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "static";
          addresses = ["203.0.113.1/24"];
          zone = "external";
          nat.enable = true;
        };
      };
      lan = {
        hardwareName = "eth1";
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
        };
      };
    };
  };

  # Config C: DHCP WAN without PD (plain DHCPv4)
  dhcpWanNoPD = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [{verdict = "accept";}];
      };
    };
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
        };
      };
      lan = {
        hardwareName = "eth1";
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
        };
      };
    };
  };

  # Config D: Multiple DHCP interfaces
  multiDhcp = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [{verdict = "accept";}];
      };
    };
    topology = {
      wan1 = {
        hardwareName = "eth0";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
        };
      };
      wan2 = {
        hardwareName = "eth1";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
        };
      };
      lan = {
        hardwareName = "eth2";
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
        };
      };
    };
  };

  # Config E: ICMP rate limiting enabled + drop logging
  # (reuse E for both ICMP rate limit and drop logging tests)
  icmpRateLimited = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [{verdict = "accept";}];
      };
    };
    firewall.icmpRateLimit = "30/second burst 60 packets";
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
        };
      };
      lan = {
        hardwareName = "eth1";
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
        };
      };
    };
  };

  # Config F: Drop logging enabled
  dropLogging = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [{verdict = "accept";}];
      };
    };
    firewall.logDropped = true;
    firewall.logDroppedRateLimit = "10/minute";
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
        };
      };
      lan = {
        hardwareName = "eth1";
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
        };
      };
    };
  };

  # ========================================================================
  # Tests
  # ========================================================================

  tests = let
    rulesetA = evalRuleset dhcpWanWithPD;
    rulesetB = evalRuleset staticWan;
    rulesetC = evalRuleset dhcpWanNoPD;
    rulesetD = evalRuleset multiDhcp;
    rulesetE = evalRuleset icmpRateLimited;
    rulesetF = evalRuleset dropLogging;
  in [
    # ======================================================================
    # Config A: DHCP WAN with PD + static LAN with dhcp6
    # ======================================================================
    (assertTrue "A: DHCPv6 client rule present"
      (contains ''iifname { "wan" } udp dport 546 accept'' rulesetA))

    (assertTrue "A: IPv4 masquerade present"
      (contains ''oifname { "wan" } masquerade'' rulesetA))

    (assertTrue "A: no IPv6 masquerade (ip6 nat has no masquerade)"
      (let
        # Extract just the ip6 nat table section
        parts = builtins.split "table ip6 nat" rulesetA;
        ip6Section =
          if builtins.length parts >= 3
          then builtins.elemAt parts 2
          else "";
      in
        notContains "masquerade" ip6Section))

    (assertTrue "A: connection tracking base rules present"
      (contains "ct state { established, related } accept" rulesetA))

    (assertTrue "A: invalid connection state dropped"
      (contains "ct state invalid drop" rulesetA))

    (assertTrue "A: NDP base rules present"
      (contains "nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert" rulesetA))

    # ======================================================================
    # Config B: Static WAN (no DHCP, no PD)
    # ======================================================================
    (assertTrue "B: no DHCPv6 client rule"
      (notContains "udp dport 546" rulesetB))

    (assertTrue "B: IPv4 masquerade still present"
      (contains ''oifname { "wan" } masquerade'' rulesetB))

    # ======================================================================
    # Config C: DHCP WAN without PD
    # ======================================================================
    (assertTrue "C: DHCPv6 client rule present (DHCP interfaces need it even without PD)"
      (contains ''iifname { "wan" } udp dport 546 accept'' rulesetC))

    # ======================================================================
    # Config D: Multiple DHCP interfaces
    # ======================================================================
    (assertTrue "D: DHCPv6 client rule uses set syntax for multiple interfaces"
      (contains ''iifname { "wan1", "wan2" } udp dport 546 accept'' rulesetD))

    # ======================================================================
    # Config E: ICMP rate limiting
    # ======================================================================
    (assertTrue "E: ICMP rate limit present in echo rules"
      (contains "echo-request, echo-reply } limit rate 30/second burst 60 packets accept" rulesetE))

    (assertTrue "E: ICMP rate limit applies to both v4 and v6"
      (contains "icmpv6 type { echo-request, echo-reply } limit rate 30/second" rulesetE))

    (assertTrue "A: no ICMP rate limit when not configured"
      (contains "echo-request, echo-reply } accept" rulesetA
        && notContains "echo-request, echo-reply } limit" rulesetA))

    # ======================================================================
    # Config F: Drop logging
    # ======================================================================
    (assertTrue "F: DROP-INPUT log prefix present"
      (contains ''log prefix "DROP-INPUT: "'' rulesetF))

    (assertTrue "F: DROP-FORWARD log prefix present"
      (contains ''log prefix "DROP-FORWARD: "'' rulesetF))

    (assertTrue "F: custom rate limit applied"
      (contains "limit rate 10/minute" rulesetF))

    (assertTrue "A: no drop logging when disabled"
      (notContains "DROP-INPUT" rulesetA
        && notContains "DROP-FORWARD" rulesetA))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-firewall-properties" {} ''
      echo "All ${toString (builtins.length tests)} firewall property tests passed"
      echo "PASS" > $out
    ''
  else throw "Firewall property tests failed"
