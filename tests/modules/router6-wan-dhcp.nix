# NixOS integration test for router6 DHCP WAN connectivity
#
# Verifies that a router with a DHCP-configured WAN interface can:
# 1. Obtain a DHCP lease from the upstream ISP
# 2. Ping the upstream gateway
# 3. Route traffic to external hosts via the default route
# 4. Serve DHCP to LAN clients
# 5. NAT LAN client traffic to external hosts
#
# Topology:
#   upstream (eth1=WAN link, eth2="internet")
#     | VLAN 1 (WAN)          | VLAN 2 ("internet")
#   router (eth1=WAN dhcp, eth2=LAN static)
#     | VLAN 3 (LAN)
#   client (eth1=LAN)
#
# The upstream node simulates an ISP: it runs a DHCP server on the WAN link
# (192.168.1.0/24), forwards traffic to a second "internet" subnet
# (10.99.99.0/24). The router must get a DHCP lease, install a default route
# via the upstream gateway, and be able to reach 10.99.99.1.

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

pkgs.testers.nixosTest {
  name = "router6-wan-dhcp";

  nodes = {
    # Simulated ISP upstream: DHCP server on WAN link + "internet" subnet
    upstream = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 1 2 ];

      networking.useDHCP = false;
      networking.firewall.enable = false;

      # eth1 = WAN link (DHCP server side), eth2 = "internet"
      networking.interfaces.eth1.ipv4.addresses = [{ address = "192.168.1.1"; prefixLength = 24; }];
      networking.interfaces.eth2.ipv4.addresses = [{ address = "10.99.99.1"; prefixLength = 24; }];

      # Enable forwarding so traffic from WAN subnet can reach "internet"
      boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;

      # Run dnsmasq as a DHCP server on the WAN link
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          dhcp-range = "192.168.1.100,192.168.1.200,255.255.255.0,1h";
          dhcp-option = [
            "option:router,192.168.1.1"
            "option:dns-server,192.168.1.1"
          ];
        };
      };
    };

    # Router under test: DHCP WAN + static LAN with NAT
    router = { config, pkgs, lib, ... }: {
      imports = [ ../../modules/router6 ];

      # eth1 = WAN (VLAN 1), eth2 = LAN (VLAN 3)
      virtualisation.vlans = [ 1 3 ];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        zones = {
          external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
          trusted = {
            icmpEcho = "enable";
            accessTo = [ "trusted" "external" ];
            inputRules = [{ verdict = "accept"; }];
          };
        };

        dns = {
          upstream = [ "192.168.1.1" ];
          useDHCPFallback = false;
          localDomain = "test.local";
        };

        topology = {
          wan = {
            hardwareName = "eth1";
            network = {
              type = "dhcp";
              zone = "external";
              nat.enable = true;
              defaultRoute = true;
            };
          };
          lan = {
            hardwareName = "eth2";
            network = {
              type = "static";
              addresses = [ "10.0.10.1/24" ];
              zone = "trusted";
              dhcp.enable = true;
            };
          };
        };
      };
    };

    # LAN client: gets DHCP from router
    client = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 3 ];
      networking.useDHCP = false;
      networking.interfaces.eth1.useDHCP = true;
    };
  };

  testScript = ''
    start_all()

    # ======================================================================
    # Phase 1: Upstream ready
    # ======================================================================
    upstream.wait_for_unit("dnsmasq.service")
    upstream.wait_until_succeeds("ip addr show eth1 | grep '192.168.1.1'")
    upstream.wait_until_succeeds("ip addr show eth2 | grep '10.99.99.1'")

    # ======================================================================
    # Phase 2: Router gets DHCP lease on WAN
    # ======================================================================
    router.wait_for_unit("systemd-networkd.service")

    # Test 1: Router obtains a DHCP lease on WAN
    print("Test 1: Router gets DHCP lease on WAN")
    router.wait_until_succeeds("ip addr show wan | grep '192.168.1'", timeout=30)
    print("PASS")

    # Test 2: Router can ping upstream gateway
    print("Test 2: Router can ping upstream gateway")
    router.succeed("ping -c 2 -W 3 192.168.1.1")
    print("PASS")

    # Test 3: Router can ping external host via default route
    # This is the key test — 10.99.99.1 is on a different subnet,
    # so it requires the default route via 192.168.1.1 to work.
    print("Test 3: Router can reach external host (default route works)")
    router.succeed("ping -c 2 -W 3 10.99.99.1")
    print("PASS")

    # Test 4: Verify no bogus device-scope default route
    # There should be a gateway route (via 192.168.1.1), NOT a device route (dev wan)
    print("Test 4: Default route uses gateway, not device-scope")
    router.succeed("ip route show default | grep 'via 192.168.1'")
    print("PASS")

    # ======================================================================
    # Phase 3: LAN client connectivity
    # ======================================================================

    # Wait for Kea DHCP server before checking client lease
    router.wait_for_unit("kea-dhcp4-server.service")

    # Test 5: Client gets DHCP from router on LAN
    print("Test 5: Client gets DHCP lease from router")
    client.wait_until_succeeds("ip addr show eth1 | grep '10.0.10'", timeout=60)
    print("PASS")

    # Test 6: Client can ping router LAN interface
    print("Test 6: Client can ping router LAN")
    client.succeed("ping -c 2 -W 3 10.0.10.1")
    print("PASS")

    # Test 7: Client can reach external host through router (NAT)
    print("Test 7: Client can reach external host via NAT")
    client.succeed("ping -c 2 -W 3 10.99.99.1")
    print("PASS")

    # ======================================================================
    # Summary
    # ======================================================================
    print("")
    print("=" * 70)
    print("WAN DHCP CONNECTIVITY TESTS COMPLETE")
    print("=" * 70)
    print("All 7 tests passed.")
    print("=" * 70)
  '';
}
