# NixOS integration test for router6 extraInputRules / extraForwardRules
#
# Verifies that extra firewall rules are rendered and enforced:
# - extraInputRules appear in nft input chain
# - extraForwardRules appear in nft forward chain
# - Zone input rules still work alongside extra rules
# - Zone ICMP echo rules still work
# - Extra input rules are scoped correctly (attacker can't reach)
#
# Topology: 3 VMs, 2 VLANs
# - router: eth1=external (203.0.113.1/24), eth2=trusted (10.0.10.1/24)
# - client: trusted (10.0.10.100/24)
# - attacker: external (203.0.113.100/24)
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-extra-rules";

    containers = {
      router = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [
          ../../modules/router6
          ../lib/test-minimal-base.nix
        ];

        virtualisation.vlans = [1 2];

        router6 = {
          enable = true;
          ulaPrefix = "fdc6:55f2:0a5e::/48";

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

          dns = {
            upstream = ["1.1.1.1"];
          };

          firewall = {
            extraInputRules = [
              {
                iifname = "eth2";
                tcp.dport = 9999;
                verdict = "accept";
              }
            ];
            extraForwardRules = [
              {
                iifname = "eth2";
                oifname = "eth1";
                tcp.dport = 8080;
                verdict = "accept";
              }
            ];
          };

          topology = {
            eth1 = {
              hardwareName = "eth1";
              network = {
                type = "static";
                addresses = ["203.0.113.1/24"];
                zone = "external";
                nat.enable = true;
              };
            };
            eth2 = {
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

        # Test exercises nftables extra rules + kresd — no DHCP probes.
        services.kea.dhcp4.enable = lib.mkForce false;
        services.kea.dhcp6.enable = lib.mkForce false;
      };

      client = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [2];
        networking = {
          useDHCP = false;
          enableIPv6 = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "10.0.10.100";
              prefixLength = 24;
            }
          ];
          defaultGateway = "10.0.10.1";
        };
        environment.systemPackages = with pkgs; [netcat-gnu];
      };

      attacker = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [1];
        networking = {
          useDHCP = false;
          enableIPv6 = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "203.0.113.100";
              prefixLength = 24;
            }
          ];
          defaultGateway = "203.0.113.1";
        };
        boot.kernel.sysctl = {
          "net.ipv6.conf.all.disable_ipv6" = 1;
          "net.ipv6.conf.default.disable_ipv6" = 1;
        };
        environment.systemPackages = with pkgs; [netcat-gnu];
      };
    };

    testScript = ''
      start_all()

      # Wait for all nodes
      router.wait_for_unit("network-online.target")
      router.wait_for_unit("nftables.service")
      client.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.100'")
      attacker.wait_until_succeeds("ip addr show eth1 | grep '203.0.113.100'")

      # Test 1: Extra input rule present in nft input chain
      print("Test 1: Extra input rule present (tcp dport 9999)")
      router.succeed("nft list chain inet filter input | grep 'tcp dport 9999'")
      print("PASS")

      # Test 2: Extra forward rule present in nft forward chain
      print("Test 2: Extra forward rule present (tcp dport 8080)")
      router.succeed("nft list chain inet filter forward | grep 'tcp dport 8080'")
      print("PASS")

      # Test 3: Zone input rules still work — client can reach router DNS
      print("Test 3: Zone input rules work (client can reach DNS port 53)")
      router.wait_for_unit("kresd@1.service")
      client.succeed("nc -z -w 2 10.0.10.1 53")
      print("PASS")

      # Test 4: Zone ICMP — client can ping router, attacker cannot
      print("Test 4: Zone ICMP (client ping OK, attacker ping blocked)")
      client.succeed("ping -c 1 -W 2 10.0.10.1")
      attacker.fail("ping -c 1 -W 2 203.0.113.1")
      print("PASS")

      # Test 5: Extra input rule scoped to eth2 — attacker cannot reach port 9999
      print("Test 5: Extra input rule scoped (attacker blocked from port 9999)")
      attacker.fail("nc -z -w 2 203.0.113.1 9999")
      print("PASS")

      # Test 6: Forward rule for eth2→eth1 tcp 8080 present in nft output
      print("Test 6: Forward rule has correct iifname/oifname")
      router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth2.*oifname.*eth1.*tcp dport 8080'")
      print("PASS")

      # Summary
      print("")
      print("=" * 70)
      print("EXTRA RULES TESTS COMPLETE")
      print("=" * 70)
      print("All 6 tests passed.")
      print("=" * 70)
    '';
  }
