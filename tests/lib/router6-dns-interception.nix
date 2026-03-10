# DNS interception property tests for router6
#
# Pure Nix evaluation tests verifying DNS interception DNAT rule generation.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-dns-interception.nix
# Or:  nix build .#checks.x86_64-linux.router6-dns-interception
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
    dns.upstream = ["10.0.11.2"];
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
          subnetId = 10;
          dhcp6.enable = true;
        };
      };
    };
  };

  # Config A: Interception disabled (default)
  configDisabled = baseConfig;

  # Config B: Interception enabled, upstream auto-excluded
  configEnabled =
    baseConfig
    // {
      dns =
        baseConfig.dns
        // {
          interception.enable = true;
        };
    };

  # Config C: Interception with extra excludes + explicit target
  configWithExcludes =
    baseConfig
    // {
      dns =
        baseConfig.dns
        // {
          interception = {
            enable = true;
            extraExcludeAddresses = ["10.0.11.99" "fdc6:55f2:0a5e:b::99"];
            target = "10.0.10.1";
            target6 = "fdc6:55f2:0a5e:a::1";
          };
        };
    };

  # Config D: IPv6-only upstream
  configV6Upstream =
    baseConfig
    // {
      dns = {
        upstream = ["fdc6:55f2:0a5e:b::2"];
        useDHCPFallback = false;
        interception.enable = true;
      };
    };

  rulesetA = evalRuleset configDisabled;
  rulesetB = evalRuleset configEnabled;
  rulesetC = evalRuleset configWithExcludes;
  rulesetD = evalRuleset configV6Upstream;

  tests = [
    # Disabled by default
    (assertTrue "disabled: no DNS interception rules"
      (notContains "DNS interception" rulesetA))

    # Enabled with auto-exclude
    (assertTrue "enabled: has IPv4 DNS interception"
      (contains "DNS interception" rulesetB))

    (assertTrue "enabled: upstream excluded from source"
      (contains "ip saddr != 10.0.11.2" rulesetB))

    (assertTrue "enabled: UDP interception"
      (contains "udp dport 53 dnat to" rulesetB))

    (assertTrue "enabled: TCP interception"
      (contains "tcp dport 53 dnat to" rulesetB))

    (assertTrue "enabled: has IPv6 DNS interception"
      (contains "IPv6 DNS interception" rulesetB))

    # Extra excludes
    (assertTrue "excludes: extra v4 address excluded"
      (contains "10.0.11.99" rulesetC))

    (assertTrue "excludes: extra v6 address excluded"
      (contains "fdc6:55f2:0a5e:b::99" rulesetC))

    (assertTrue "excludes: explicit v4 target used"
      (contains "dnat to 10.0.10.1:53" rulesetC))

    (assertTrue "excludes: explicit v6 target used"
      (contains "dnat to [fdc6:55f2:0a5e:a::1]:53" rulesetC))

    # IPv6 upstream
    (assertTrue "v6-upstream: v6 source excluded"
      (contains "ip6 saddr != fdc6:55f2:0a5e:b::2" rulesetD))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-dns-interception" {} ''
      echo "All ${toString (builtins.length tests)} DNS interception tests passed"
      echo "PASS" > $out
    ''
  else throw "DNS interception tests failed"
