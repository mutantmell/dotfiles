# Egress filtering property tests for router6
#
# Pure Nix evaluation tests verifying output chain generation
# for accept, drop, and log egress policies.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-egress-properties.nix
# Or:  nix build .#checks.x86_64-linux.router6-egress-properties
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

  # Config A: default (accept)
  configAccept = baseConfig;

  # Config B: drop policy
  configDrop =
    baseConfig
    // {
      firewall = {
        egressPolicy = "drop";
        egressRules = [
          {
            tcp.dport = 53;
            verdict = "accept";
            comment = "DNS";
          }
          {
            udp.dport = 123;
            verdict = "accept";
            comment = "NTP";
          }
        ];
      };
    };

  # Config C: log policy
  configLog =
    baseConfig
    // {
      firewall = {
        egressPolicy = "log";
        egressLogPrefix = "TEST-EGRESS: ";
        egressRules = [
          {
            tcp.dport = 443;
            verdict = "accept";
            comment = "HTTPS";
          }
        ];
      };
    };

  rulesetAccept = evalRuleset configAccept;
  rulesetDrop = evalRuleset configDrop;
  rulesetLog = evalRuleset configLog;

  tests = [
    # Accept mode: empty output chain
    (assertTrue "accept: policy accept"
      (contains "chain output" rulesetAccept
        && contains "policy accept" rulesetAccept))

    (assertTrue "accept: no egress base rules"
      (notContains "Base egress rules" rulesetAccept))

    # Drop mode: policy drop with base rules
    (assertTrue "drop: policy drop"
      (contains "chain output" rulesetDrop
        && contains "policy drop" rulesetDrop))

    (assertTrue "drop: has base egress rules"
      (contains "ct state { established, related } accept" rulesetDrop
        && contains ''oifname "lo" accept'' rulesetDrop))

    (assertTrue "drop: has user egress rules"
      (contains "tcp dport 53 accept" rulesetDrop
        && contains "udp dport 123 accept" rulesetDrop))

    (assertTrue "drop: no log prefix"
      (notContains "EGRESS-UNMATCHED" rulesetDrop))

    # Log mode: policy accept with base rules + log
    (assertTrue "log: policy accept"
      (contains "output" rulesetLog
        && contains "policy accept" rulesetLog))

    (assertTrue "log: has base egress rules"
      (contains "Base egress rules" rulesetLog))

    (assertTrue "log: has user egress rules"
      (contains "tcp dport 443 accept" rulesetLog))

    (assertTrue "log: has custom log prefix"
      (contains ''log prefix "TEST-EGRESS: "'' rulesetLog))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-egress-properties" {} ''
      echo "All ${toString (builtins.length tests)} egress property tests passed"
      echo "PASS" > $out
    ''
  else throw "Egress property tests failed"
