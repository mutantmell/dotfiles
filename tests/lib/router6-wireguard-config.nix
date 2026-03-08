# WireGuard config tests for router6
#
# Pure Nix evaluation tests verifying:
# - WireGuard netdev generation (Kind, ListenPort, PrivateKeyFile)
# - WireGuard network unit generation
# - openFirewall rule generation (combined UDP port set)
#
# Run: nix-instantiate --eval --strict tests/lib/router6-wireguard-config.nix
# Or:  nix build .#checks.x86_64-linux.router6-wireguard-config
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

  evalRuleset = router6Config: (evalConfig router6Config).networking.nftables.ruleset;

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;
  notContains = needle: haystack: !contains needle haystack;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  assertEq = name: a: b:
    if a == b
    then true
    else throw "FAIL: ${name}\n  Expected: ${builtins.toJSON b}\n  Got:      ${builtins.toJSON a}";

  assertHasAttr = name: attr: set:
    if builtins.hasAttr attr set
    then true
    else throw "FAIL: ${name} — missing attribute '${attr}'";

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
      vpn = {
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
    };
  };

  # Config A: openFirewall = true, port = 51820
  configA =
    baseConfig
    // {
      topology =
        baseConfig.topology
        // {
          wg0 = {
            kind = "wireguard";
            network = {
              type = "static";
              addresses = ["10.100.0.1/24"];
              zone = "vpn";
            };
            wireguard = {
              privateKeyFile = "/run/secrets/wg0-key";
              port = 51820;
              openFirewall = true;
              peers = [
                {
                  publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                  allowedIPs = ["10.100.0.0/24"];
                }
              ];
            };
          };
        };
    };

  # Config B: openFirewall = false
  configB =
    baseConfig
    // {
      topology =
        baseConfig.topology
        // {
          wg0 = {
            kind = "wireguard";
            network = {
              type = "static";
              addresses = ["10.100.0.1/24"];
              zone = "vpn";
            };
            wireguard = {
              privateKeyFile = "/run/secrets/wg0-key";
              port = 51820;
              openFirewall = false;
            };
          };
        };
    };

  # Config C: Two WG interfaces, both openFirewall
  configC =
    baseConfig
    // {
      topology =
        baseConfig.topology
        // {
          wg0 = {
            kind = "wireguard";
            network = {
              type = "static";
              addresses = ["10.100.0.1/24"];
              zone = "vpn";
            };
            wireguard = {
              privateKeyFile = "/run/secrets/wg0-key";
              port = 51820;
              openFirewall = true;
            };
          };
          wg1 = {
            kind = "wireguard";
            network = {
              type = "static";
              addresses = ["10.100.1.1/24"];
              zone = "vpn";
            };
            wireguard = {
              privateKeyFile = "/run/secrets/wg1-key";
              port = 51821;
              openFirewall = true;
            };
          };
        };
    };

  # Config D: No port, no openFirewall
  configD =
    baseConfig
    // {
      topology =
        baseConfig.topology
        // {
          wg0 = {
            kind = "wireguard";
            network = {
              type = "static";
              addresses = ["10.100.0.1/24"];
              zone = "vpn";
            };
            wireguard = {
              privateKeyFile = "/run/secrets/wg0-key";
            };
          };
        };
    };

  evalA = evalConfig configA;
  evalB = evalConfig configB;
  evalC = evalConfig configC;
  evalD = evalConfig configD;

  rulesetA = evalRuleset configA;
  rulesetB = evalRuleset configB;
  rulesetC = evalRuleset configC;
  rulesetD = evalRuleset configD;

  tests = [
    # Config A: openFirewall = true
    (assertTrue "A: WG UDP port in ruleset"
      (contains "udp dport { 51820 } accept" rulesetA))

    (assertHasAttr "A: netdev 30-wg0 exists"
      "30-wg0"
      evalA.systemd.network.netdevs)

    (assertEq "A: netdev Kind = wireguard"
      evalA.systemd.network.netdevs."30-wg0".netdevConfig.Kind "wireguard")

    (assertEq "A: netdev Name = wg0"
      evalA.systemd.network.netdevs."30-wg0".netdevConfig.Name "wg0")

    (assertEq "A: ListenPort = 51820"
      evalA.systemd.network.netdevs."30-wg0".wireguardConfig.ListenPort
      51820)

    (assertEq "A: PrivateKeyFile set"
      evalA.systemd.network.netdevs."30-wg0".wireguardConfig.PrivateKeyFile "/run/secrets/wg0-key")

    (assertHasAttr "A: network 40-wg0 exists"
      "40-wg0"
      evalA.systemd.network.networks)

    # Config B: openFirewall = false
    (assertTrue "B: no WG UDP port in ruleset"
      (notContains "udp dport { 51820 }" rulesetB))

    # Config C: Two WG interfaces, both openFirewall
    (assertTrue "C: combined WG ports in ruleset"
      (contains "udp dport { 51820, 51821 } accept" rulesetC))

    # Config D: No port, no openFirewall
    (assertHasAttr "D: netdev 30-wg0 exists"
      "30-wg0"
      evalD.systemd.network.netdevs)

    (assertTrue "D: no ListenPort in wireguardConfig"
      (!(builtins.hasAttr "ListenPort" evalD.systemd.network.netdevs."30-wg0".wireguardConfig)))

    (assertTrue "D: no udp dport in ruleset"
      (notContains "udp dport" rulesetD))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-wireguard-config" {} ''
      echo "All ${toString (builtins.length tests)} WireGuard config tests passed"
      echo "PASS" > $out
    ''
  else throw "WireGuard config tests failed"
