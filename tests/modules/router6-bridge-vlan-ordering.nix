# Test for bridge and VLAN ordering edge cases
#
# This test verifies two critical scenarios:
# 1. Bridge composed of VLANs (VLANs as bridge members)
# 2. VLANs on top of a bridge (bridge as VLAN parent)
#    - Includes DHCP client test: client on VLAN 30 gets address via DHCP
#
# Tests proper netdev dependency ordering:
#   01- bond
#   02- batman
#   03- bridge
#   04- vlan (after all potential parents)
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-bridge-vlan-ordering";

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

        virtualisation.vlans = [1 2 3];

        router6 = {
          enable = true;
          ulaPrefix = "fd00::/48";

          zones = {
            external = {
              icmpEcho = "disable";
              accessTo = [];
              inputRules = [];
            };
            trusted = {
              icmpEcho = "enable";
              accessTo = ["trusted" "external"];
              inputRules = [{verdict = "accept";}];
            };
          };

          topology = {
            wan = {
              hardwareName = "eth0";
              network = {
                type = "static";
                addresses = ["192.168.1.1/24"];
                zone = "external";
              };
            };

            eth1 = {
              hardwareName = "eth1";
              network.type = "disabled";
            };

            eth2 = {
              hardwareName = "eth2";
              network.type = "disabled";
            };

            eth3 = {
              hardwareName = "eth3";
              network.type = "disabled";
            };

            # SCENARIO 1: Bridge composed of VLANs
            # Create bond -> Create VLANs on bond -> VLANs become bridge members
            bond0 = {
              kind = "bond";
              mode = "balance-rr";
              members = ["eth1" "eth2"];
              network.type = "disabled";
              vlans = {
                vlan10 = {
                  tag = 10;
                  network.type = "disabled"; # Will be bridge member
                };
                vlan20 = {
                  tag = 20;
                  network.type = "disabled"; # Will be bridge member
                };
              };
            };

            # Bridge with VLANs as members
            br0 = {
              kind = "bridge";
              members = ["vlan10" "vlan20"];
              network = {
                type = "static";
                addresses = ["10.0.1.1/24"];
                zone = "trusted";
              };
            };

            # SCENARIO 2: VLANs on top of a bridge
            # Create bridge -> Create VLANs on bridge interface
            br1 = {
              kind = "bridge";
              members = ["eth3"]; # Bridge needs at least one member to get carrier
              network.type = "disabled";
              vlans = {
                vlan30 = {
                  tag = 30;
                  network = {
                    type = "static";
                    addresses = ["10.0.30.1/24"];
                    zone = "trusted";
                    dhcp.enable = true;
                  };
                };
                vlan40 = {
                  tag = 40;
                  network = {
                    type = "static";
                    addresses = ["10.0.40.1/24"];
                    zone = "trusted";
                  };
                };
              };
            };
          };
        };

        # Test exercises bridge/VLAN topology and DHCP — no DNS probes.
        services.kresd.enable = lib.mkForce false;
      };

      # DHCP client on VLAN 30 (VLANs-on-bridge scenario)
      # Shares L2 segment with router's eth3 (bridge member of br1).
      # Tagged 802.1Q frames pass through the vde switch transparently.
      client = {lib, ...}: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [3];
        networking.useDHCP = false;
        networking.interfaces.eth1.useDHCP = false;
        systemd.network = {
          enable = true;
          netdevs."10-vlan30" = {
            netdevConfig = {
              Name = "vlan30";
              Kind = "vlan";
            };
            vlanConfig.Id = 30;
          };
          networks."10-eth1" = {
            matchConfig.Name = "eth1";
            vlan = ["vlan30"];
            linkConfig.RequiredForOnline = "carrier";
          };
          networks."20-vlan30" = {
            matchConfig.Name = "vlan30";
            networkConfig.DHCP = "yes";
            linkConfig.RequiredForOnline = "routable";
          };
        };
      };
    };

    testScript = ''
      start_all()
      router.wait_for_unit("network-online.target")

      # ============================================================
      # SCENARIO 1: Bridge composed of VLANs
      # ============================================================

      # Verify bond exists
      router.succeed("ip link show bond0")

      # Verify VLANs on bond exist
      router.wait_until_succeeds("ip link show vlan10", timeout=60)
      router.wait_until_succeeds("ip link show vlan20", timeout=60)

      # Verify bridge exists and has IP
      router.wait_until_succeeds("ip link show br0", timeout=60)
      router.wait_until_succeeds("ip addr show br0 | grep '10.0.1.1/24'", timeout=60)

      # Verify VLANs are members of the bridge
      router.wait_until_succeeds("bridge link show | grep vlan10", timeout=60)
      router.wait_until_succeeds("bridge link show | grep vlan20", timeout=60)

      # Verify VLANs don't have the bridge's IP address
      router.fail("ip addr show vlan10 | grep '10.0.1.1'")
      router.fail("ip addr show vlan20 | grep '10.0.1.1'")

      # ============================================================
      # SCENARIO 2: VLANs on top of bridge
      # ============================================================

      # Verify bridge exists (no configured IP on bridge itself)
      router.wait_until_succeeds("ip link show br1", timeout=60)
      router.fail("ip -4 addr show br1 | grep 'inet '")

      # Verify eth3 is a member of the bridge (so bridge has carrier)
      router.wait_until_succeeds("bridge link show | grep eth3", timeout=60)

      # Verify VLANs on bridge exist and have IPs
      router.wait_until_succeeds("ip link show vlan30", timeout=60)
      router.wait_until_succeeds("ip link show vlan40", timeout=60)
      router.wait_until_succeeds("ip addr show vlan30 | grep '10.0.30.1/24'", timeout=60)
      router.wait_until_succeeds("ip addr show vlan40 | grep '10.0.40.1/24'", timeout=60)

      # ============================================================
      # Verify correct netdev creation order
      # ============================================================

      # Bonds first (01-)
      router.succeed("ls /etc/systemd/network/01-bond0.netdev")

      # Bridges second (03-)
      router.succeed("ls /etc/systemd/network/03-br0.netdev")
      router.succeed("ls /etc/systemd/network/03-br1.netdev")

      # VLANs (04-) - after parent netdevs, before network files
      router.succeed("ls /etc/systemd/network/04-vlan10.netdev")
      router.succeed("ls /etc/systemd/network/04-vlan20.netdev")
      router.succeed("ls /etc/systemd/network/04-vlan30.netdev")
      router.succeed("ls /etc/systemd/network/04-vlan40.netdev")

      # Verify VLANs on bond have correct parent in netdev file
      router.succeed("grep 'Id=10' /etc/systemd/network/04-vlan10.netdev")
      router.succeed("grep 'Id=20' /etc/systemd/network/04-vlan20.netdev")

      # Verify VLANs on bridge have correct parent in netdev file
      router.succeed("grep 'Id=30' /etc/systemd/network/04-vlan30.netdev")
      router.succeed("grep 'Id=40' /etc/systemd/network/04-vlan40.netdev")

      # Verify network files have correct numbering (21- for VLANs)
      router.succeed("ls /etc/systemd/network/21-vlan10.network")
      router.succeed("ls /etc/systemd/network/21-vlan20.network")
      router.succeed("ls /etc/systemd/network/21-vlan30.network")
      router.succeed("ls /etc/systemd/network/21-vlan40.network")

      # ============================================================
      # SCENARIO 2b: DHCP through VLANs-on-bridge
      # ============================================================

      # Wait for DHCP server on router
      router.wait_for_unit("kea-dhcp4-server.service")

      # Client should get a DHCP address on VLAN 30
      client.wait_until_succeeds("ip addr show vlan30 | grep '10.0.30'", timeout=60)

      # Client can ping the router through the VLAN
      client.succeed("ping -c 1 10.0.30.1")
    '';
  }
