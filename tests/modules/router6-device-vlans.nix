# NixOS integration test for router6 device types with and without VLANs
#
# Verifies that all device types (physical, bond, batman) work correctly
# both with and without VLAN subinterfaces.
#
# Tests:
# 1. Batman device without VLANs (simple mesh with IP)
# 2. Batman device with VLANs (parent disabled, VLAN has IP)
# 3. Bond without VLANs (simple bond with IP)
# 4. Physical interface without VLANs (implicit - bond members)
# 5. Physical interface with VLANs (parent disabled, VLAN has IP)
# 6. Correct numeric prefixes for all systemd-networkd files

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

pkgs.testers.nixosTest {
  name = "router6-device-vlans";

  nodes = {
    router = { config, pkgs, ... }: {
      imports = [ ../../modules/router6 ];

      # Virtual network setup
      virtualisation.vlans = [ 1 2 3 ];

      router6 = {
        enable = true;
        ulaPrefix = "fd00::/48";

        topology = {
          # WAN interface
          wan = {
            hardwareName = "eth0";
            network = {
              type = "static";
              addresses = ["192.168.1.1/24"];
              trust = "external";
              nat.enable = true;
            };
          };

          # Physical interface for bonding (no VLANs)
          eth1 = {
            hardwareName = "eth1";
            network.type = "disabled";
          };

          # Physical interface for bonding (no VLANs)
          eth2 = {
            hardwareName = "eth2";
            network.type = "disabled";
          };

          # Physical interface with VLANs
          eth3 = {
            hardwareName = "eth3";
            network.type = "disabled";
            vlans = {
              vlan30 = {
                tag = 30;
                network = {
                  type = "static";
                  addresses = ["10.0.30.1/24"];
                  trust = "trusted";
                };
              };
            };
          };

          # Bond without VLANs (simple bond with IP)
          bond0 = {
            kind = "bond";
            mode = "active-backup";
            members = ["eth1" "eth2"];
            network = {
              type = "static";
              addresses = ["10.0.1.1/24"];
              trust = "management";
            };
          };

          # Batman device without VLANs (simple mesh with IP)
          bat0 = {
            kind = "batman";
            batman = {
              gatewayMode = "server";
              routingAlgorithm = "batman-v";
            };
            network = {
              type = "static";
              addresses = ["10.0.10.1/24"];
              trust = "trusted";
            };
          };

          # Batman device with VLANs
          bat1 = {
            kind = "batman";
            batman = {
              gatewayMode = "off";
            };
            network.type = "disabled";
            vlans = {
              vlan20 = {
                tag = 20;
                network = {
                  type = "static";
                  addresses = ["10.0.20.1/24"];
                  trust = "trusted";
                };
              };
            };
          };
        };
      };
    };
  };

  testScript = ''
    start_all()

    # Wait for router networking
    router.wait_for_unit("network-online.target")

    # Test 1: Batman device without VLANs exists and has IP
    router.succeed("ip link show bat0")
    router.succeed("ip addr show bat0 | grep '10.0.10.1/24'")

    # Test 2: Batman device with VLANs - parent exists, no IP
    router.succeed("ip link show bat1")
    router.fail("ip addr show bat1 | grep '10.0.20.1'")

    # Test 3: Batman VLAN exists and has IP
    router.succeed("ip link show vlan20")
    router.succeed("ip addr show vlan20 | grep '10.0.20.1/24'")

    # Test 4: Bond without VLANs has IP
    router.succeed("ip link show bond0")
    router.succeed("ip addr show bond0 | grep '10.0.1.1/24'")

    # Test 5: Physical interface with VLANs - parent exists, no IP
    router.succeed("ip link show eth3")
    router.fail("ip addr show eth3 | grep '10.0.30.1'")

    # Test 6: Physical VLAN exists and has IP
    router.succeed("ip link show vlan30")
    router.succeed("ip addr show vlan30 | grep '10.0.30.1/24'")

    # Test 7: Verify systemd-networkd files have correct numeric prefixes
    # Batman netdevs should have 00- prefix
    router.succeed("ls /etc/systemd/network/00-bat0.netdev")
    router.succeed("ls /etc/systemd/network/00-bat1.netdev")

    # VLAN netdevs should have 01- prefix
    router.succeed("ls /etc/systemd/network/01-vlan20.netdev")
    router.succeed("ls /etc/systemd/network/01-vlan30.netdev")

    # Bond netdev should have 03- prefix
    router.succeed("ls /etc/systemd/network/03-bond0.netdev")

    # Regular networks should have 10- prefix
    router.succeed("ls /etc/systemd/network/10-bat0.network")
    router.succeed("ls /etc/systemd/network/10-bond0.network")

    # VLAN networks should have 21- prefix
    router.succeed("ls /etc/systemd/network/21-vlan20.network")
    router.succeed("ls /etc/systemd/network/21-vlan30.network")
  '';
}
