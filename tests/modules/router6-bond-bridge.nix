# NixOS integration test for router6 bond and bridge functionality
#
# Tests:
# 1. Bond creation with LACP mode
# 2. Bond member attachment (eth1, eth2)
# 3. VLANs on bond
# 4. Bridge creation
# 5. Bridge member attachment (VLANs from different parents)
# 6. Bridge network config applied correctly
# 7. subnetId → IPv6 auto-generation
# 8. Bridged VLANs have no IP (disabled)
# 9. Non-bridged VLANs have their own IP
# 10. DHCP/DHCPv6 through bridge
# 11. End-to-end connectivity

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

pkgs.testers.nixosTest {
  name = "router6-bond-bridge";

  nodes = {
    router = { config, pkgs, ... }: {
      imports = [ ../../modules/router6 ];

      # Virtual network setup - eth0 is implicit, eth1/eth2 for bonding, VLAN 10 for bridge
      virtualisation.vlans = [ 1 2 10 ];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        topology = {
          # Physical interfaces for bonding
          eth1 = {
            hardwareName = "eth1";
            network.type = "disabled";
          };

          eth2 = {
            hardwareName = "eth2";
            network.type = "disabled";
          };

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

          # Bond with LACP
          bond0 = {
            kind = "bond";
            mode = "802.3ad";
            members = ["eth1" "eth2"];
            lacpTransmitRate = "fast";
            network = {
              type = "disabled";
              mtu = 1536;
            };
            vlans = {
              vlan10 = {
                tag = 10;
                network.type = "disabled";  # Will be bridged
              };
              vlan20 = {
                tag = 20;
                network = {
                  type = "static";
                  addresses = ["10.0.20.1/24"];
                  trust = "trusted";
                  dhcp.enable = true;
                  dhcp6.enable = true;
                };
              };
            };
          };

          # Another device with VLAN 10 to bridge
          bat0 = {
            kind = "batman";
            batman = {
              gatewayMode = "off";
            };
            vlans = {
              vlan10bat = {
                tag = 10;
                network.type = "disabled";  # Will be bridged
              };
            };
          };

          # Bridge aggregating VLANs from bond0 and bat0
          brMGMT = {
            kind = "bridge";
            members = ["vlan10" "vlan10bat"];
            network = {
              type = "static";
              addresses = ["10.0.10.1/24"];
              subnetId = 10;  # Should generate fdc6:55f2:0a5e:a::1/64
              trust = "management";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };
        };
      };
    };

    client = { ... }: {
      virtualisation.vlans = [10];
      networking = {
        useDHCP = false;
        interfaces.eth1.useDHCP = true;
      };
    };
  };

  testScript = ''
    start_all()

    # Wait for router networking
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("kea-dhcp4-server.service")
    router.wait_for_unit("kresd@1.service")

    # Test 1: Bond exists and has correct mode
    router.succeed("ip link show bond0")
    router.succeed("cat /sys/class/net/bond0/bonding/mode | grep '802.3ad'")

    # Test 2: Bond members are attached
    router.succeed("ip link show")  # Debug: show all interfaces
    router.succeed("cat /sys/class/net/bond0/bonding/slaves")  # Debug: show actual slaves
    router.succeed("cat /sys/class/net/bond0/bonding/slaves | grep eth1")
    router.succeed("cat /sys/class/net/bond0/bonding/slaves | grep eth2")

    # Test 3: VLAN on bond exists
    router.succeed("ip link show vlan10")
    router.succeed("cat /sys/class/net/vlan10/operstate | grep up")

    # Test 4: Bridge exists
    router.succeed("ip link show brMGMT")

    # Test 5: Bridge members are attached
    router.succeed("bridge link | grep vlan10")
    router.succeed("bridge link | grep vlan10bat")

    # Test 6: Bridge has correct IPv4 address
    router.succeed("ip addr show brMGMT | grep '10.0.10.1/24'")

    # Test 7: Bridge has auto-generated IPv6 from subnetId
    router.succeed("ip addr show brMGMT | grep 'fdc6:55f2:0a5e:a::1/64'")

    # Test 8: Non-bridged VLAN (vlan20) has its own config
    router.succeed("ip addr show vlan20 | grep '10.0.20.1/24'")
    router.succeed("ip addr show vlan20 | grep 'fdc6:55f2:0a5e:14::1/64'")

    # Test 9: DHCP works through bridge
    client.wait_for_unit("network-online.target")
    client.wait_until_succeeds("ip addr show eth1 | grep '10.0.10'", timeout=30)

    # Test 10: IPv6 SLAAC works through bridge
    client.wait_until_succeeds("ip -6 addr show eth1 | grep 'fdc6:55f2:0a5e:a'", timeout=60)

    # Test 11: Client can reach router
    client.succeed("ping -c 1 10.0.10.1")
    client.succeed("ping -c 1 fdc6:55f2:0a5e:a::1")
  '';
}
