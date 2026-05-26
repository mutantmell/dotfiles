# NixOS integration test for router6 batman-adv wired-only topology
#
# Tests that the bat0-only bridge topology works correctly:
# 1. bat0 batadv interface is created (batman-adv module loaded)
# 2. VLAN sub-interface on bat0 is created
# 3. Bridge over bat0 VLAN has correct addresses
# 4. Batman hard interface has MTU 1536
# 5. Bridge member (bat0 VLAN) is attached
# 6. No bond0 interface is created (wired-only replaces old bond0)
# 7. DHCP server is active on bridge
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-batman-wired-only";

  nodes = {
    router = {
      config,
      pkgs,
      ...
    }: {
      imports = [../../modules/router6];

      # batman-adv is in-tree; load it explicitly for the test VM
      boot.kernelModules = ["batman_adv"];

      # eth0 = WAN (VLAN 1), eth1 = batman hard interface (VLAN 2)
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

        topology = {
          # WAN interface — kernel name as topology key (hardwareName rename is broken)
          eth0 = {
            kind = "physical";
            network = {
              type = "static";
              addresses = ["203.0.113.1/24"];
              zone = "external";
              nat.enable = true;
            };
          };

          # Batman hard interface — MTU 1536 for batman-adv overhead headroom
          eth1 = {
            kind = "physical";
            network = {
              type = "disabled";
              mtu = 1536;
            };
          };

          # Batman-adv device — single wired hard interface, no bond
          bat0 = {
            kind = "batman";
            members = ["eth1"];
            batman = {
              gatewayMode = "off";
              routingAlgorithm = "batman-v";
            };
            network.type = "disabled";
            vlans = {
              # VLAN 10 — will be bridged into brLAN below
              vlan10 = {
                tag = 10;
                network.type = "disabled";
              };
            };
          };

          # Bridge over bat0 VLAN 10 — trusted devices
          brLAN = {
            kind = "bridge";
            members = ["vlan10"];
            network = {
              type = "static";
              addresses = ["10.0.10.1/24"];
              zone = "trusted";
              subnetId = 10;
              dhcp.enable = true;
              dhcp6 = {
                enable = true;
                dnsAddress = "fdc6:55f2:0a5e:a::1";
              };
            };
          };
        };
      };
    };
  };

  testScript = ''
    start_all()
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("kea-dhcp4-server.service")

    # 1. batman-adv module is loaded
    router.succeed("lsmod | grep batman_adv")

    # 2. bat0 batadv interface exists
    router.succeed("ip link show bat0")

    # 3. eth1 is enslaved to bat0 mesh (legacy /sys/class/net/<iface>/batman_adv/
    #    was removed from upstream kernel; ip link's "master bat0" is canonical)
    router.succeed("ip link show eth1 | grep 'master bat0'")

    # 4. eth1 (batman hard interface) has MTU 1536
    router.succeed("ip link show eth1 | grep ' mtu 1536 '")

    # 5. VLAN sub-interface on bat0 exists
    router.wait_until_succeeds("ip link show vlan10", timeout=30)

    # 6. Bridge brLAN exists
    router.wait_until_succeeds("ip link show brLAN", timeout=30)

    # 7. Bridge has correct IPv4 address
    router.wait_until_succeeds("ip addr show brLAN | grep '10.0.10.1/24'", timeout=30)

    # 8. Bridge has auto-generated ULA IPv6 from subnetId 10 = 0xa
    #    (kernel/iproute2 display RFC 5952 canonical form: 0a5e → a5e)
    router.wait_until_succeeds("ip addr show brLAN | grep 'fdc6:55f2:a5e:a::1'", timeout=30)

    # 9. vlan10 is attached to brLAN bridge
    router.wait_until_succeeds("bridge link | grep vlan10", timeout=30)

    # 10. No bond0 — wired batman replaces the old bond topology
    router.fail("ip link show bond0")

    # 11. bat0 netdev file uses correct ordering (02- prefix, after bonds/before VLANs)
    router.succeed("ls /etc/systemd/network/02-bat0.netdev")
    router.succeed("ls /etc/systemd/network/04-vlan10.netdev")
    router.succeed("ls /etc/systemd/network/03-brLAN.netdev")
  '';
}
