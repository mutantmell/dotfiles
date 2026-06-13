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
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-bond-bridge";

    containers = {
      router = {
        config,
        pkgs,
        ...
      }: {
        imports = [
          ../../modules/router6
          ../lib/test-minimal-base.nix
        ];

        # Virtual network setup - eth0 is WAN, eth1/eth2 for bonding, VLAN 10 for bridge
        virtualisation.vlans = [1 2 10];

        router6 = {
          enable = true;
          ulaPrefix = "fdc6:55f2:0a5e::/48";

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
                zone = "external";
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
                  network.type = "disabled"; # Will be bridged
                };
                vlan20 = {
                  tag = 20;
                  network = {
                    type = "static";
                    addresses = ["10.0.20.1/24"];
                    zone = "trusted";
                    dhcp.enable = true;
                    dhcp6 = {
                      enable = true;
                      dnsAddress = "fdc6:55f2:a5e:14::1";
                    };
                  };
                };
              };
            };

            # Physical interface on the client network (VLAN 10)
            eth3 = {
              hardwareName = "eth3";
              network.type = "disabled"; # No IP, will be bridged
            };

            # Bridge with VLAN from bond and physical interface
            brMGMT = {
              kind = "bridge";
              members = ["vlan10" "eth3"];
              network = {
                type = "static";
                addresses = ["10.0.10.1/24"];
                subnetId = 10; # Should generate fdc6:55f2:0a5e:a::1/64
                zone = "management";
                dhcp.enable = true;
                dhcp6 = {
                  enable = true;
                  dnsAddress = "fdc6:55f2:a5e:a::1";
                };
              };
            };
          };
        };
      };

      client = {...}: {
        imports = [../lib/test-minimal-base.nix];
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
      router.wait_until_succeeds("ip link show vlan10", timeout=30)
      router.wait_until_succeeds("cat /sys/class/net/vlan10/operstate | grep up", timeout=30)

      # Test 4: Bridge exists
      router.wait_until_succeeds("ip link show brMGMT", timeout=30)

      # Verify correct netdev ordering (bond before VLAN before bridge, VLAN before network files)
      router.succeed("ls /etc/systemd/network/01-bond0.netdev")
      router.succeed("ls /etc/systemd/network/03-brMGMT.netdev")
      router.succeed("ls /etc/systemd/network/04-vlan10.netdev")
      router.succeed("ls /etc/systemd/network/04-vlan20.netdev")

      # Test 5: Bridge members are attached (VLAN and physical interface)
      router.wait_until_succeeds("bridge link | grep vlan10", timeout=30)
      router.wait_until_succeeds("bridge link | grep eth3", timeout=30)

      # Test 6: Bridge has correct IPv4 address
      router.wait_until_succeeds("ip addr show brMGMT | grep '10.0.10.1/24'", timeout=30)

      # Test 7: Bridge has auto-generated (normalized) IPv6 from subnetId
      router.wait_until_succeeds("ip addr show brMGMT | grep 'fdc6:55f2:a5e:a::1/64'", timeout=30)

      # Test 8: Non-bridged VLAN (vlan20) has its own config
      router.wait_until_succeeds("ip addr show vlan20 | grep '10.0.20.1/24'", timeout=30)
      router.wait_until_succeeds("ip addr show vlan20 | grep 'fdc6:55f2:a5e:14::1/64'", timeout=30)

      # Test 9: DHCP works through bridge
      # Note: Don't wait for network-online.target as it may not activate with legacy networking
      client.wait_until_succeeds("ip addr show eth1 | grep '10.0.10'", timeout=30)

      # Test 10: IPv6 SLAAC works through bridge
      client.wait_until_succeeds("ip -6 addr show eth1 | grep 'fdc6:55f2:a5e:a'", timeout=60)

      # Test 11: Client can reach router
      client.succeed("ping -c 1 10.0.10.1")
      client.wait_until_succeeds("ping -c 1 fdc6:55f2:a5e:a::1", timeout=30)
    '';
  }
