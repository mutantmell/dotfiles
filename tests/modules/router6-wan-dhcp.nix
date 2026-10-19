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
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  routerWan = "eth1";
  routerLan = "eth2";
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-wan-dhcp";

    containers = {
      # Simulated ISP upstream: DHCP server on WAN link + "internet" subnet
      upstream = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [1 2];

        networking.useDHCP = false;
        networking.firewall.enable = false;

        # eth1 = WAN link (DHCP server side), eth2 = "internet"
        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = "192.168.1.1";
            prefixLength = 24;
          }
        ];
        networking.interfaces.eth2.ipv4.addresses = [
          {
            address = "10.99.99.1";
            prefixLength = 24;
          }
        ];

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

        # eth1 = WAN (VLAN 1), eth2 = LAN (VLAN 3), eth3 = optional LAN
        virtualisation.vlans = [1 3 4];

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
              accessTo = ["trusted" "external"];
              inputRules = [{verdict = "accept";}];
            };
          };

          dns = {
            upstream = ["192.168.1.1"];
            localDomain = "test.local";
          };

          topology = {
            ${routerWan} = {
              kind = "physical";
              network = {
                type = "dhcp";
                zone = "external";
                nat.enable = true;
                defaultRoute = true;
              };
            };
            ${routerLan} = {
              kind = "physical";
              network = {
                type = "static";
                addresses = ["10.0.10.1/24"];
                zone = "trusted";
                dhcp.enable = true;
              };
            };
            eth3 = {
              kind = "physical";
              network = {
                type = "static";
                addresses = ["10.0.20.1/24"];
                zone = "trusted";
                dhcp.enable = true;
                required = false;
              };
            };
          };
        };

        # Test exercises WAN DHCP + LAN DHCP — no DNS or DHCPv6 probes.
        services.kresd.enable = lib.mkForce false;
        services.kea.dhcp6.enable = lib.mkForce false;
      };

      # LAN client: gets DHCP from router
      client = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [3];
        networking.useDHCP = false;
        networking.interfaces.eth1.useDHCP = true;
      };
    };

    testScript = ''
      import time

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
      router.wait_until_succeeds("ip addr show ${routerWan} | grep '192.168.1'", timeout=30)
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

      # Startup must wait for the serving interface, beyond the old 20s
      # retry window. Stop networkd temporarily so it cannot raise the link.
      # A condition also prevents Kea's Wants= from starting it again.
      router.succeed("mkdir -p /run/systemd/system/systemd-networkd.service.d")
      router.succeed("printf '[Unit]\\nConditionPathExists=!/run/router6-hold-networkd\\n' > /run/systemd/system/systemd-networkd.service.d/test.conf")
      router.succeed("systemctl daemon-reload")
      router.succeed("systemctl stop kea-dhcp4-server")
      router.succeed("networkctl down ${routerLan} eth3")
      # Let networkd publish the down state before freezing it. wait-online
      # reads these files, not just kernel link flags.
      for iface in ["${routerLan}", "eth3"]:
          router.wait_until_succeeds(f"grep -q '^OPER_STATE=off$' /run/systemd/netif/links/$(cat /sys/class/net/{iface}/ifindex)")
      router.succeed("touch /run/router6-hold-networkd")
      router.succeed("systemctl stop systemd-networkd")
      router.succeed("systemctl start --no-block kea-dhcp4-server")
      router.wait_until_succeeds("test $(systemctl show -p SubState --value kea-dhcp4-server) = start-pre")
      time.sleep(25)
      router.succeed("test $(systemctl show -p SubState --value kea-dhcp4-server) = start-pre")
      router.succeed("rm /run/router6-hold-networkd")
      router.succeed("systemctl start systemd-networkd")
      router.succeed("networkctl up ${routerLan} eth3")
      router.wait_for_unit("kea-dhcp4-server.service")

      # Bypass the readiness wait to exercise Kea's independent socket retry
      # protection. A fresh DHCP exchange must succeed after the late link
      # returns, without an operator restarting Kea.
      router.succeed("systemctl stop kea-dhcp4-server")
      router.succeed("networkctl down ${routerLan} eth3")
      # Let networkd publish the down state before freezing it. wait-online
      # reads these files, not just kernel link flags.
      for iface in ["${routerLan}", "eth3"]:
          router.wait_until_succeeds(f"grep -q '^OPER_STATE=off$' /run/systemd/netif/links/$(cat /sys/class/net/{iface}/ifindex)")
      router.succeed("touch /run/router6-hold-networkd")
      router.succeed("systemctl stop systemd-networkd")
      router.succeed("mkdir -p /run/systemd/system/kea-dhcp4-server.service.d")
      router.succeed("printf '[Service]\\nExecStartPre=\\n' > /run/systemd/system/kea-dhcp4-server.service.d/test.conf")
      router.succeed("systemctl daemon-reload; systemctl start kea-dhcp4-server")
      kea_pid = router.succeed("systemctl show -p MainPID --value kea-dhcp4-server").strip()
      time.sleep(25)
      router.succeed("systemctl is-active kea-dhcp4-server")
      router.succeed("rm /run/router6-hold-networkd")
      router.succeed("systemctl start systemd-networkd")
      router.succeed("networkctl up ${routerLan} eth3")
      client.wait_until_succeeds("${pkgs.busybox}/bin/udhcpc -f -n -q -i eth1 -t 3 -T 2 -s /bin/true 2>&1 | grep 'lease of 10.0.10.'", timeout=60)
      assert router.succeed("systemctl show -p MainPID --value kea-dhcp4-server").strip() == kea_pid

      # One unplugged optional LAN must not block service on the healthy LAN.
      # Keep networkd running: wait-online needs its configured/address state
      # for the healthy LAN. networkctl down holds eth3 administratively down
      # without freezing or removing the healthy LAN's readiness information.
      router.succeed("systemctl stop kea-dhcp4-server")
      router.succeed("networkctl down eth3")
      router.wait_until_succeeds("grep -q '^OPER_STATE=off$' /run/systemd/netif/links/$(cat /sys/class/net/eth3/ifindex)")
      router.succeed("rm /run/systemd/system/kea-dhcp4-server.service.d/test.conf")
      router.succeed("systemctl daemon-reload; systemctl start --no-block kea-dhcp4-server")
      router.wait_for_unit("kea-dhcp4-server.service", timeout=30)
      client.wait_until_succeeds("${pkgs.busybox}/bin/udhcpc -f -n -q -i eth1 -t 3 -T 2 -s /bin/true 2>&1 | grep 'lease of 10.0.10.'", timeout=30)
      router.succeed("test $(cat /sys/class/net/eth3/operstate) = down")

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
