# DNAT property tests for router6
#
# Pure Nix evaluation tests verifying:
# - DNAT prerouting rules for port forwards
# - Forward chain accept rules for DNAT destinations
# - sourceInterface filtering
# - proto = "both" syntax
# - extraNat* escape hatches (ip and ip6 tables)
# - Multiple port forwards
#
# Run: nix-instantiate --eval --strict tests/lib/router6-dnat-properties.nix
# Or:  nix build .#checks.x86_64-linux.router6-dnat-properties
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
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

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;
  notContains = needle: haystack: !contains needle haystack;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  baseConfig = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    dns.useDHCPFallback = false;
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

  mkConfig = firewall:
    baseConfig
    // {
      firewall = (baseConfig.firewall or {}) // firewall;
    };

  # Config A: Basic TCP port forward, no sourceInterface
  rulesetA = evalRuleset (mkConfig {
    portForwards = [
      {
        proto = "tcp";
        sourcePort = 8080;
        destination = "10.0.10.50:80";
      }
    ];
  });

  # Config B: sourceInterface = "wan"
  rulesetB = evalRuleset (mkConfig {
    portForwards = [
      {
        proto = "tcp";
        sourcePort = 443;
        destination = "10.0.10.50:443";
        sourceInterface = "wan";
      }
    ];
  });

  # Config C: proto = "both"
  rulesetC = evalRuleset (mkConfig {
    portForwards = [
      {
        proto = "both";
        sourcePort = 53;
        destination = "10.0.10.5:53";
      }
    ];
  });

  # Config D: extraNatRules + extraNatPostroutingRules
  rulesetD = evalRuleset (mkConfig {
    extraNatRules = ["tcp dport 9090 redirect to :8080"];
    extraNatPostroutingRules = [
      {
        ip.saddr = "10.0.10.0/24";
        verdict = "masquerade";
      }
    ];
  });

  # Config E: extraNat6Rules + extraNat6PostroutingRules
  rulesetE = evalRuleset (mkConfig {
    extraNat6Rules = ["tcp dport 9090 redirect to :8080"];
    extraNat6PostroutingRules = [
      {
        ip6.saddr = "fdc6:55f2:0a5e::/48";
        verdict = "masquerade";
      }
    ];
  });

  # Config F: Multiple port forwards
  rulesetF = evalRuleset (mkConfig {
    portForwards = [
      {
        proto = "tcp";
        sourcePort = 8080;
        destination = "10.0.10.50:80";
      }
      {
        proto = "tcp";
        sourcePort = 8443;
        destination = "10.0.10.50:443";
      }
    ];
  });

  tests = [
    # Config A: Basic TCP port forward
    (assertTrue "A: DNAT rule present"
      (contains "tcp dport 8080 dnat to 10.0.10.50:80" rulesetA))

    (assertTrue "A: forward accept rule present (uses dest port after DNAT)"
      (contains "ip daddr 10.0.10.50 tcp dport 80 accept" rulesetA))

    # Config B: sourceInterface = "wan"
    (assertTrue "B: DNAT with iifname"
      (contains ''iifname "wan" tcp dport 443 dnat to 10.0.10.50:443'' rulesetB))

    (assertTrue "B: forward accept rule has iifname matching sourceInterface"
      (contains ''iifname "wan" ip daddr 10.0.10.50 tcp dport 443 accept'' rulesetB))

    # Config C: proto = "both"
    (assertTrue "C: DNAT with meta l4proto"
      (contains "meta l4proto { tcp, udp } th dport 53 dnat to 10.0.10.5:53" rulesetC))

    (assertTrue "C: forward accept with meta l4proto"
      (contains "meta l4proto { tcp, udp } ip daddr 10.0.10.5 th dport 53 accept" rulesetC))

    # Config D: extraNatRules
    (assertTrue "D: extra NAT prerouting rule"
      (contains "tcp dport 9090 redirect to :8080" rulesetD))

    (assertTrue "D: extra NAT postrouting rule (masquerade)"
      (contains "masquerade" rulesetD))

    (assertTrue "D: extra NAT postrouting has saddr"
      (contains "10.0.10.0/24" rulesetD))

    # Config E: extraNat6Rules in ip6 nat table
    (assertTrue "E: extra IPv6 NAT prerouting rule"
      (contains "tcp dport 9090 redirect to :8080" rulesetE))

    (assertTrue "E: extra IPv6 NAT postrouting has ULA"
      (contains "fdc6:55f2:0a5e::/48" rulesetE))

    # Config F: Multiple port forwards
    (assertTrue "F: first DNAT rule"
      (contains "tcp dport 8080 dnat to 10.0.10.50:80" rulesetF))

    (assertTrue "F: second DNAT rule"
      (contains "tcp dport 8443 dnat to 10.0.10.50:443" rulesetF))

    (assertTrue "F: first forward accept (uses dest port 80)"
      (contains "ip daddr 10.0.10.50 tcp dport 80 accept" rulesetF))

    (assertTrue "F: second forward accept (uses dest port 443)"
      (contains "ip daddr 10.0.10.50 tcp dport 443 accept" rulesetF))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-dnat-properties" {} ''
      echo "All ${toString (builtins.length tests)} DNAT property tests passed"
      echo "PASS" > $out
    ''
  else throw "DNAT property tests failed"
