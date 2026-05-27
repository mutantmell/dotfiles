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
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-device-vlans";

  nodes = {
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

      # Virtual network setup
      virtualisation.vlans = [1 2 3 4];

      router6 = {
        enable = true;
        ulaPrefix = "fd00::/48";

        zones = {
          external = {
            icmpEcho = "disable";
            accessTo = [];
            inputRules = [];
          };
          management = {
            icmpEcho = "enable";
            accessTo = ["management" "trusted" "external"];
            inputRules = [{verdict = "accept";}];
          };
          trusted = {
            icmpEcho = "enable";
            accessTo = ["management" "trusted" "external"];
            inputRules = [{verdict = "accept";}];
          };
        };

        topology = {
          # WAN interface
          wan = {
            hardwareName = "eth0";
            network = {
              type = "static";
              addresses = ["192.168.1.1/24"];
              zone = "external";
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
                  zone = "trusted";
                };
              };
            };
          };

          # Physical interface for batman mesh
          eth4 = {
            hardwareName = "eth4";
            network.type = "disabled";
          };

          # Bond without VLANs (simple bond with IP)
          bond0 = {
            kind = "bond";
            mode = "active-backup";
            members = ["eth1" "eth2"];
            network = {
              type = "static";
              addresses = ["10.0.1.1/24"];
              zone = "management";
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
              zone = "trusted";
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
                  zone = "trusted";
                };
              };
            };
          };

          # Batman device with members (physical interface)
          bat2 = {
            kind = "batman";
            members = ["eth4"];
            batman = {
              gatewayMode = "client";
            };
            network = {
              type = "static";
              addresses = ["10.0.40.1/24"];
              zone = "trusted";
            };
          };
        };
      };

      # Test exercises pure topology/addressing — no DNS or DHCP probes.
      services.kresd.enable = lib.mkForce false;
      services.kea.dhcp4.enable = lib.mkForce false;
      services.kea.dhcp6.enable = lib.mkForce false;
      # kea normally wants network-online.target; without it nothing pulls
      # up that target. Anchor it to multi-user.target so it still activates.
      systemd.targets.network-online.wantedBy = ["multi-user.target"];
    };
  };

  testScript = ''
    start_all()

    # Wait for router networking
    router.wait_for_unit("network-online.target")

    # Test 1: Batman device without VLANs or members exists and has IP
    router.wait_until_succeeds("ip link show bat0", timeout=30)
    router.wait_until_succeeds("ip addr show bat0 | grep '10.0.10.1/24'", timeout=30)

    # Test 2: Batman device with VLANs - parent exists, no IP
    router.wait_until_succeeds("ip link show bat1", timeout=30)
    router.fail("ip addr show bat1 | grep '10.0.20.1'")

    # Test 3: Batman VLAN exists and has IP
    router.wait_until_succeeds("ip link show vlan20", timeout=30)
    router.wait_until_succeeds("ip addr show vlan20 | grep '10.0.20.1/24'", timeout=30)

    # Test 4: Bond without VLANs has IP
    router.wait_until_succeeds("ip link show bond0", timeout=30)
    router.wait_until_succeeds("ip addr show bond0 | grep '10.0.1.1/24'", timeout=30)

    # Test 5: Physical interface with VLANs - parent exists, no IP
    router.wait_until_succeeds("ip link show eth3", timeout=30)
    router.fail("ip addr show eth3 | grep '10.0.30.1'")

    # Test 6: Physical VLAN exists and has IP
    router.wait_until_succeeds("ip link show vlan30", timeout=30)
    router.wait_until_succeeds("ip addr show vlan30 | grep '10.0.30.1/24'", timeout=30)

    # Test 7: Batman device with members - member is attached
    router.wait_until_succeeds("ip link show bat2", timeout=30)
    router.wait_until_succeeds("ip addr show bat2 | grep '10.0.40.1/24'", timeout=30)
    # Verify eth4 is attached to bat2 (check systemd-networkd config)
    router.succeed("grep -q 'BatmanAdvanced=bat2' /etc/systemd/network/10-eth4.network")

    # Test 8: Verify systemd-networkd files have correct numeric prefixes (dependency order)
    # Bonds should have 01- prefix (early, can be batman members)
    router.succeed("ls /etc/systemd/network/01-bond0.netdev")

    # Batman netdevs should have 02- prefix (after bonds)
    router.succeed("ls /etc/systemd/network/02-bat0.netdev")
    router.succeed("ls /etc/systemd/network/02-bat1.netdev")
    router.succeed("ls /etc/systemd/network/02-bat2.netdev")

    # Bridge netdevs should have 03- prefix (after bonds/batman)
    # (No bridges in this test, but would be 03- if present)

    # VLAN netdevs should have 04- prefix (after parent netdevs, before network files)
    router.succeed("ls /etc/systemd/network/04-vlan20.netdev")
    router.succeed("ls /etc/systemd/network/04-vlan30.netdev")

    # Regular networks should have 10- prefix
    router.succeed("ls /etc/systemd/network/10-bat0.network")
    router.succeed("ls /etc/systemd/network/10-bond0.network")

    # VLAN networks should have 21- prefix
    router.succeed("ls /etc/systemd/network/21-vlan20.network")
    router.succeed("ls /etc/systemd/network/21-vlan30.network")
  '';
}
