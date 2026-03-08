# PPPoE configuration eval test for router6
#
# Pure Nix evaluation tests verifying:
# - PPPoE type accepted without errors
# - Basic systemd-networkd config generated
# - IP forwarding enabled
# - NAT masquerade present
#
# Run: nix-instantiate --eval --strict tests/lib/router6-pppoe-config.nix
# Or:  nix build .#checks.x86_64-linux.router6-pppoe-config
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  evalConfig = router6Config: let
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
    eval.config;

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  assertEq = name: a: b:
    if a == b
    then true
    else throw "FAIL: ${name}\n  Expected: ${builtins.toJSON b}\n  Got:      ${builtins.toJSON a}";

  # Config A: PPPoE WAN with static LAN
  configA = {
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
          type = "pppoe";
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

  evalA = evalConfig configA;
  rulesetA = evalA.networking.nftables.ruleset;

  tests = [
    # PPPoE type evaluates without error
    (assertTrue "A: systemd.network.networks has wan entry"
      (builtins.hasAttr "10-wan" evalA.systemd.network.networks))

    (assertEq "A: IPv4 forwarding enabled"
      evalA.boot.kernel.sysctl."net.ipv4.conf.all.forwarding"
      true)

    (assertTrue "A: nftables ruleset is non-empty"
      (builtins.stringLength rulesetA > 0))

    (assertTrue "A: NAT masquerade present for wan"
      (contains "masquerade" rulesetA))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-pppoe-config" {} ''
      echo "All ${toString (builtins.length tests)} PPPoE config tests passed"
      echo "PASS" > $out
    ''
  else throw "PPPoE config tests failed"
