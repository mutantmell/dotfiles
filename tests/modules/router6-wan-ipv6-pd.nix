# NixOS integration test for router6 WAN IPv6 Prefix Delegation
#
# Verifies that a router with DHCPv6-PD can:
# 1. Request and receive a delegated /48 prefix from an ISP
# 2. Distribute /64 subnets to LAN interfaces via DHCPPrefixDelegation
# 3. Advertise delegated prefixes alongside ULA via Router Advertisements
# 4. Forward IPv6 traffic end-to-end without NAT66
#
# Topology:
#   isp (eth1=WAN link)
#     | VLAN 1 (WAN)
#   router (eth1=WAN dhcp+PD, eth2=LAN1 trusted, eth3=LAN2 iot)
#     | VLAN 2 (LAN1)      | VLAN 3 (LAN2)
#   client (eth1=LAN1)
#
# The ISP node simulates an ISP: Kea DHCPv6 server with PD pool + radvd for RAs.
# Based on the nixpkgs reference test at nixos/tests/systemd-networkd-ipv6-prefix-delegation.nix
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-wan-ipv6-pd";

  nodes = {
    # Simulated ISP: DHCPv6 server with PD pool + radvd
    isp = {
      config,
      pkgs,
      lib,
      ...
    }: {
      virtualisation.vlans = [1];

      networking = {
        useDHCP = false;
        firewall.enable = false;
        interfaces.eth1 = lib.mkForce {};
      };

      systemd.network = {
        enable = true;
        networks."eth1" = {
          matchConfig.Name = "eth1";
          address = ["2001:db8::1/64"];
          networkConfig = {
            IPv4Forwarding = true;
            IPv6Forwarding = true;
          };
        };
      };

      # Kea needs CAP_NET_ADMIN for the run-script hook to install routes
      systemd.services.kea-dhcp6-server.serviceConfig = {
        AmbientCapabilities = ["CAP_NET_ADMIN"];
        CapabilityBoundingSet = ["CAP_NET_ADMIN"];
      };

      services = {
        # DHCPv6 server: hands out /48 prefixes from 2001:db8:1000::/36
        # and /128 addresses from 2001:db8::/32
        kea.dhcp6 = {
          enable = true;
          settings = {
            interfaces-config.interfaces = ["eth1"];
            subnet6 = [
              {
                id = 1;
                interface = "eth1";
                subnet = "2001:db8::/32";
                pd-pools = [
                  {
                    prefix = "2001:db8:1000::";
                    prefix-len = 36;
                    delegated-len = 48;
                  }
                ];
                pools = [
                  {
                    pool = "2001:db8:0000:0000::-2001:db8:0fff:ffff::ffff";
                  }
                ];
              }
            ];

            # Run-script hook: install routes for delegated prefixes
            # In production this would be BGP/NETCONF; in test we use ip route
            hooks-libraries = [
              {
                library = "${pkgs.kea}/lib/kea/hooks/libdhcp_run_script.so";
                parameters = {
                  name = pkgs.writeShellScript "kea-run-hooks" ''
                    export PATH="${lib.makeBinPath (with pkgs; [coreutils iproute2])}"

                    set -euxo pipefail

                    leases6_committed() {
                      for i in $(seq $LEASES6_SIZE); do
                        idx=$((i-1))
                        prefix_var="LEASES6_AT''${idx}_ADDRESS"
                        plen_var="LEASES6_AT''${idx}_PREFIX_LEN"

                        ip -6 route replace ''${!prefix_var}/''${!plen_var} via $QUERY6_REMOTE_ADDR dev $QUERY6_IFACE_NAME
                      done
                    }

                    unknown_handler() {
                      echo "Unhandled function call ''${*}"
                      exit 123
                    }

                    case "$1" in
                        "leases6_committed")
                            leases6_committed
                            ;;
                        *)
                            unknown_handler "''${@}"
                            ;;
                    esac
                  '';
                  sync = false;
                };
              }
            ];
          };
        };

        # Router Advertisements: set Managed flag so clients do DHCPv6
        radvd = {
          enable = true;
          config = ''
            interface eth1 {
              AdvSendAdvert on;
              AdvManagedFlag on;
              AdvOtherConfigFlag off;
              prefix ::/64 {
                AdvOnLink on;
                AdvAutonomous on;
              };
            };
          '';
        };
      };
    };

    # Router under test: DHCP WAN with PD + two LAN interfaces
    router = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [../../modules/router6];

      # eth1 = WAN (VLAN 1), eth2 = LAN1 (VLAN 2), eth3 = LAN2 (VLAN 3)
      virtualisation.vlans = [1 2 3];

      # Debug networkd for PD troubleshooting
      systemd.services.systemd-networkd.environment.SYSTEMD_LOG_LEVEL = "debug";

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
          iot = {
            icmpEcho = "enable";
            accessTo = ["external"];
            inputRules = [{verdict = "accept";}];
          };
        };

        dns = {
          upstream = ["2001:db8::1"];
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
              ipv6PrefixDelegation = {
                enable = true;
                prefixLength = 48;
              };
            };
          };
          lan1 = {
            hardwareName = "eth2";
            network = {
              type = "static";
              addresses = ["10.0.20.1/24"];
              zone = "trusted";
              subnetId = 1;
              dhcp.enable = true;
              dhcp6 = {
                enable = true;
                mode = "stateful";
                dnsAddress = "fdc6:55f2:a5e:1::1";
              };
              pdSubnetId = "0x1";
            };
          };
          lan2 = {
            hardwareName = "eth3";
            network = {
              type = "static";
              addresses = ["10.0.30.1/24"];
              zone = "iot";
              subnetId = 2;
              dhcp6 = {
                enable = true;
                mode = "slaac";
                dnsAddress = "fdc6:55f2:a5e:2::1";
              };
              pdSubnetId = "0x2";
            };
          };
        };
      };
    };

    # Client on LAN1: accepts RAs, uses DHCPv6
    client = {
      config,
      pkgs,
      lib,
      ...
    }: {
      virtualisation.vlans = [2];

      networking.useDHCP = false;

      systemd.network = {
        enable = true;
        networks."10-eth1" = {
          matchConfig.Name = "eth1";
          networkConfig = {
            DHCP = "yes";
            IPv6AcceptRA = true;
          };
          dhcpV6Config = {
            UseAddress = true;
            UseDNS = true;
          };
        };
      };

      # Accept RAs even with DHCPv6 (for SLAAC addresses)
      boot.kernel.sysctl = {
        "net.ipv6.conf.eth1.accept_ra" = 2;
        "net.ipv6.conf.eth1.autoconf" = 1;
      };
    };
  };

  testScript = ''
    start_all()

    # ======================================================================
    # Phase 1: ISP ready
    # ======================================================================
    isp.wait_for_unit("kea-dhcp6-server.service")
    isp.wait_for_unit("radvd.service")
    isp.wait_until_succeeds("ip -6 addr show eth1 | grep '2001:db8::1'")

    # ======================================================================
    # Phase 2: Router boots and gets PD from ISP
    # ======================================================================
    router.wait_for_unit("systemd-networkd.service")

    # Test 1: Router gets connectivity to ISP
    print("Test 1: Router can ping ISP")
    router.wait_until_succeeds("ping -6 -c 1 -W 5 2001:db8::1", timeout=60)
    print("PASS")

    # Test 2: Router has GUA address on LAN1 from delegated prefix
    print("Test 2: Router has delegated prefix on LAN1")
    router.wait_until_succeeds("ip -6 addr show lan1 | grep '2001:db8:1'", timeout=60)
    print("PASS")

    # Test 3: Router has ULA address on LAN1
    print("Test 3: Router has ULA address on LAN1")
    router.succeed("ip -6 addr show lan1 | grep 'fdc6:55f2'")
    print("PASS")

    # Test 4: Router has GUA address on LAN2 from delegated prefix
    print("Test 4: Router has delegated prefix on LAN2")
    router.wait_until_succeeds("ip -6 addr show lan2 | grep '2001:db8:1'", timeout=30)
    print("PASS")

    # ======================================================================
    # Phase 3: Client gets addresses
    # ======================================================================
    client.wait_for_unit("systemd-networkd.service")

    # Test 5: Client gets GUA via SLAAC from delegated prefix
    print("Test 5: Client gets GUA from delegated prefix")
    client.wait_until_succeeds("ip -6 addr show eth1 | grep '2001:db8:1'", timeout=60)
    print("PASS")

    # Test 6: Client gets ULA via SLAAC from static prefix
    print("Test 6: Client gets ULA address")
    client.wait_until_succeeds("ip -6 addr show eth1 | grep 'fdc6:55f2'", timeout=60)
    print("PASS")

    # ======================================================================
    # Phase 4: End-to-end connectivity
    # ======================================================================

    # Test 7: Client can ping ISP via GUA (end-to-end IPv6 forwarding)
    print("Test 7: Client can ping ISP (end-to-end GUA forwarding)")
    client.wait_until_succeeds("ping -6 -c 1 -W 5 2001:db8::1", timeout=30)
    print("PASS")

    # Test 8: Client can ping router's ULA (ULA still works alongside GUA)
    print("Test 8: Client can ping router ULA")
    client.succeed("ping -6 -c 1 -W 5 fdc6:55f2:a5e:1::1")
    print("PASS")

    # Test 9: No IPv6 masquerade/NAT66 rule (opinionated: no NAT for IPv6)
    print("Test 9: No IPv6 NAT masquerade rule")
    nat_rules = router.succeed("nft list table ip6 nat 2>/dev/null || echo 'no ip6 nat table'")
    assert "masquerade" not in nat_rules, f"Found IPv6 masquerade rule: {nat_rules}"
    print("PASS")

    # ======================================================================
    # Summary
    # ======================================================================
    print("")
    print("=" * 70)
    print("WAN IPv6 PREFIX DELEGATION TESTS COMPLETE")
    print("=" * 70)
    print("All 9 tests passed.")
    print("=" * 70)
  '';
}
