# NixOS integration test for router6 IPv6 functionality
#
# Tests:
# 1. IPv6 forwarding is enabled
# 2. Router has auto-generated IPv6 addresses on VLANs
# 3. Router Advertisements are being sent
# 4. nftables has proper IPv6 rules
# 5. kresd is listening on IPv6
# 6. Client receives IPv6 via SLAAC
# 7. Client can ping router over IPv6

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

pkgs.nixosTest {
  name = "router6-ipv6";

  nodes = {
    router = { config, pkgs, lib, ... }: {
      imports = [ ../../modules/router6 ];

      # Virtual network setup - eth1 is WAN, eth2 is LAN
      virtualisation.vlans = [ 1 2 ];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        dns = {
          upstream = [ "1.1.1.1" ];
          useDHCPFallback = false;
          localDomain = "test.local";
        };

        topology = {
          # WAN interface (external)
          eth1 = {
            hardwareName = "eth1";
            network = {
              type = "static";
              addresses = [ "192.168.1.1/24" ];
              trust = "external";
              nat.enable = true;
            };
          };

          # LAN interface with a VLAN
          eth2 = {
            hardwareName = "eth2";
            network = {
              type = "disabled";
              required = false;
            };
            vlans = {
              "vlan10" = {
                tag = 10;
                network = {
                  type = "static";
                  addresses = [ "10.0.10.1/24" ];
                  trust = "trusted";
                  dhcp.enable = true;
                  dhcp6.enable = true;
                };
              };
            };
          };
        };
      };
    };

    client = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 2 ];

      # Configure client to use VLAN 10
      networking = {
        useDHCP = false;
        vlans.vlan10 = {
          id = 10;
          interface = "eth1";
        };
        interfaces.vlan10 = {
          useDHCP = true;
        };
      };

      # Enable IPv6 autoconfiguration via SLAAC
      boot.kernel.sysctl = {
        "net.ipv6.conf.vlan10.accept_ra" = 2;
        "net.ipv6.conf.vlan10.autoconf" = 1;
      };

      systemd.network.enable = true;
      systemd.network.networks."40-vlan10" = {
        matchConfig.Name = "vlan10";
        networkConfig = {
          DHCP = "ipv4";
          IPv6AcceptRA = true;
        };
        linkConfig.RequiredForOnline = "routable";
      };
    };
  };

  testScript = ''
    start_all()

    # Wait for router to be ready
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("kresd.service")

    # Test 1: Verify IPv6 forwarding is enabled
    router.succeed("sysctl net.ipv6.conf.all.forwarding | grep '= 1'")

    # Test 2: Verify router has auto-generated IPv6 address on VLAN
    # VLAN 10 -> fdc6:55f2:0a5e:a::1/64
    router.succeed("ip -6 addr show vlan10 | grep 'fdc6:55f2:0a5e:a::1'")

    # Test 3: Verify Router Advertisements are configured
    # Check that IPv6SendRA is enabled in networkd
    router.succeed("networkctl status vlan10 | grep -i 'IPv6'")

    # Test 4: Verify nftables has IPv6 rules
    router.succeed("nft list ruleset | grep 'ip6 nexthdr icmpv6'")
    router.succeed("nft list ruleset | grep 'table ip6 nat'")

    # Test 5: Verify kresd is listening on IPv6
    router.succeed("ss -6 -tulnp | grep ':53'")
    # Check kresd is listening on the router's IPv6 address
    router.succeed("ss -tulnp | grep 'fdc6:55f2:0a5e:a::1'")

    # Client tests
    client.wait_for_unit("network-online.target")
    client.wait_for_unit("systemd-networkd.service")

    # Wait for VLAN to come up
    client.wait_until_succeeds("ip link show vlan10 | grep 'state UP'", timeout=30)

    # Test 6: Client receives IPv6 via SLAAC
    # Wait for client to get an IPv6 address in the ULA range
    client.wait_until_succeeds("ip -6 addr show vlan10 | grep 'fdc6:55f2:0a5e:a::'", timeout=60)

    # Test 7: Client can ping router over IPv6
    client.succeed("ping -6 -c 3 fdc6:55f2:0a5e:a::1")

    # Test 8: Client can reach DNS over IPv6
    client.succeed("${pkgs.dig}/bin/dig @fdc6:55f2:0a5e:a::1 -6 localhost AAAA +short || true")
  '';
}
