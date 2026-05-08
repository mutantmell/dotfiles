# Assertion tests for router6
#
# Pure Nix evaluation tests verifying that invalid configs
# trigger the correct assertions with expected error messages.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-assertions.nix
# Or:  nix build .#checks.x86_64-linux.router6-assertions
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  # Evaluate a router6 config and return failed assertions
  evalAssertions = router6Config: let
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
    builtins.filter (x: !x.assertion) eval.config.assertions;

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  # Assert that a config fires an assertion containing the expected message
  assertFiresWith = name: expectedMsg: router6Config: let
    failed = evalAssertions router6Config;
  in
    assertTrue "${name} (expected: '${expectedMsg}')"
    (builtins.any (a: contains expectedMsg a.message) failed);

  baseZones = {
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

  baseTopology = {
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

  baseConfig = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    dns.useDHCPFallback = false;
    zones = baseZones;
    topology = baseTopology;
  };

  tests = [
    # 1. WireGuard openFirewall without port
    (assertFiresWith "WG openFirewall without port" "openFirewall requires port" (
      baseConfig
      // {
        topology =
          baseTopology
          // {
            wg0 = {
              kind = "wireguard";
              network = {
                type = "static";
                addresses = ["10.100.0.1/24"];
                zone = "trusted";
              };
              wireguard = {
                privateKeyFile = "/run/secrets/wg0-key";
                openFirewall = true;
                # port intentionally omitted
              };
            };
          };
      }
    ))

    # 2. accessTo + forwardRules overlap
    (assertFiresWith "accessTo + forwardRules overlap" "appears in both accessTo and forwardRules" (
      baseConfig
      // {
        zones =
          baseZones
          // {
            trusted =
              baseZones.trusted
              // {
                accessTo = ["external"];
                forwardRules.external = [
                  {
                    tcp.dport = 80;
                    verdict = "accept";
                  }
                ];
              };
          };
      }
    ))

    # 3. inputRules with iifname
    (assertFiresWith "inputRules with iifname" "must not specify iifname" (
      baseConfig
      // {
        zones =
          baseZones
          // {
            trusted =
              baseZones.trusted
              // {
                inputRules = [
                  {
                    iifname = "eth1";
                    verdict = "accept";
                  }
                ];
              };
          };
      }
    ))

    # 4. forwardRules with oifname
    (assertFiresWith "forwardRules with oifname" "must not specify iifname/oifname" (
      baseConfig
      // {
        zones =
          baseZones
          // {
            trusted =
              baseZones.trusted
              // {
                accessTo = [];
                forwardRules.external = [
                  {
                    oifname = "eth0";
                    verdict = "accept";
                  }
                ];
              };
          };
      }
    ))

    # 5. forwardRules references unknown zone
    (assertFiresWith "forwardRules unknown zone" "references unknown zone" (
      baseConfig
      // {
        zones =
          baseZones
          // {
            trusted =
              baseZones.trusted
              // {
                accessTo = [];
                forwardRules.nonexistent = [
                  {
                    tcp.dport = 80;
                    verdict = "accept";
                  }
                ];
              };
          };
      }
    ))

    # 6. Bond with no members
    (assertFiresWith "Bond with no members" "has no members defined" (
      baseConfig
      // {
        topology =
          baseTopology
          // {
            bond0 = {
              kind = "bond";
              network = {
                type = "disabled";
              };
            };
          };
      }
    ))

    # 7. pdSubnetId without PD source
    (assertFiresWith "pdSubnetId without PD" "ipv6PrefixDelegation" (
      baseConfig
      // {
        topology =
          baseTopology
          // {
            lan =
              baseTopology.lan
              // {
                network =
                  baseTopology.lan.network
                  // {
                    pdSubnetId = "1";
                  };
              };
          };
      }
    ))

    # 8. dhcp6.enable on DHCP WAN interface
    (assertFiresWith "dhcp6 on DHCP WAN" "cannot be set on a DHCP client interface" (
      baseConfig
      // {
        topology =
          baseTopology
          // {
            wan = {
              hardwareName = "eth0";
              network = {
                type = "dhcp";
                zone = "external";
                nat.enable = true;
                dhcp6 = {
                  enable = true;
                  dnsAddress = "fdc6:55f2:0a5e:1::1";
                };
              };
            };
          };
      }
    ))

    # 9. Non-WG inputRule on WAN zone fires assertion (a)
    (assertFiresWith "WAN zone non-WG inputRule fires security assertion" "must only accept WireGuard ports" (
      baseConfig
      // {
        zones =
          baseZones
          // {
            external =
              baseZones.external
              // {
                inputRules = [
                  {
                    tcp.dport = 22;
                    verdict = "accept";
                  }
                ];
              };
          };
      }
    ))

    # 10. DHCP server on NAT (WAN) interface fires assertion (b)
    (assertFiresWith "DHCP on NAT interface fires security assertion" "nat.enable = true and dhcp.enable = true" (
      baseConfig
      // {
        topology =
          baseTopology
          // {
            wan =
              baseTopology.wan
              // {
                network =
                  baseTopology.wan.network
                  // {
                    dhcp.enable = true;
                  };
              };
          };
      }
    ))

    # 11. icmpEcho=enable on NAT zone fires assertion (c)
    (assertFiresWith "icmpEcho=enable on WAN zone fires security assertion" "icmpEcho != 'disable'" (
      baseConfig
      // {
        zones =
          baseZones
          // {
            external =
              baseZones.external
              // {
                icmpEcho = "enable";
              };
          };
      }
    ))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-assertions" {} ''
      echo "All ${toString (builtins.length tests)} assertion tests passed"
      echo "PASS" > $out
    ''
  else throw "Assertion tests failed"
