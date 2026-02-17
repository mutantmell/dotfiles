# NixOS integration test for router6 firewall zone behavior
#
# Comprehensive multi-zone test with all current trust levels represented.
# Verifies input chain (router access) and forward chain (inter-zone traffic).
#
# Tests:
# Input chain:
#  1. management → router: full access
#  2. trusted → router: full access
#  3. untrusted → router: DNS/DHCP only
#  4. isolated → router: nothing (not even DNS/DHCP)
#  5. external → router: stealth (nothing)
#  6. ICMP echo: internal only (mgmt/trusted/untrusted can ping, external/isolated cannot)
#
# Forward chain:
#  7.  management → trusted: allowed
#  8.  management → untrusted: allowed
#  9.  management → external: allowed (NAT)
# 10.  trusted → management: allowed
# 11.  trusted → untrusted: allowed
# 12.  trusted → external: allowed (NAT)
# 13.  untrusted → external: allowed (NAT)
# 14.  untrusted → management: blocked
# 15.  untrusted → trusted: blocked
# 16.  isolated → anything: blocked
# 17.  external → internal: blocked

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

pkgs.testers.nixosTest {
  name = "router6-firewall-zones";

  nodes = {
    router = { config, pkgs, lib, ... }: {
      imports = [ ../../modules/router6 ];

      # Virtual network setup:
      # eth1 (vlan1) = WAN/external (203.0.113.0/24)
      # eth2 (vlan2) = management  (10.0.10.0/24)
      # eth3 (vlan3) = trusted     (10.0.20.0/24)
      # eth4 (vlan4) = untrusted   (10.0.30.0/24)
      # eth5 (vlan5) = isolated    (10.0.40.0/24)
      virtualisation.vlans = [ 1 2 3 4 5 ];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        zones = {
          external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
          management = {
            icmpEcho = "enable";
            accessTo = [ "management" "trusted" "untrusted" "external" ];
            inputRules = [{ verdict = "accept"; }];
          };
          trusted = {
            icmpEcho = "enable";
            accessTo = [ "management" "trusted" "untrusted" "external" ];
            inputRules = [{ verdict = "accept"; }];
          };
          untrusted = {
            icmpEcho = "enable";
            accessTo = [ "external" ];
            inputRules = [
              { udp.dport = [ 53 67 547 ]; verdict = "accept"; }
              { tcp.dport = 53; verdict = "accept"; }
            ];
          };
          isolated = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
        };

        dns = {
          upstream = [ "1.1.1.1" ];
          useDHCPFallback = false;
          localDomain = "test.local";
        };

        topology = {
          eth1 = {
            hardwareName = "eth1";
            network = {
              type = "static";
              addresses = [ "203.0.113.1/24" ];
              zone = "external";
              nat.enable = true;
            };
          };
          eth2 = {
            hardwareName = "eth2";
            network = {
              type = "static";
              addresses = [ "10.0.10.1/24" ];
              zone = "management";
              dhcp.enable = true;
            };
          };
          eth3 = {
            hardwareName = "eth3";
            network = {
              type = "static";
              addresses = [ "10.0.20.1/24" ];
              zone = "trusted";
              dhcp.enable = true;
            };
          };
          eth4 = {
            hardwareName = "eth4";
            network = {
              type = "static";
              addresses = [ "10.0.30.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
            };
          };
          eth5 = {
            hardwareName = "eth5";
            network = {
              type = "static";
              addresses = [ "10.0.40.1/24" ];
              zone = "isolated";
            };
          };
        };
      };
    };

    # Management node
    mgmt = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 2 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.10.100"; prefixLength = 24; }];
        defaultGateway = "10.0.10.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # Trusted node
    trusted = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 3 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.20.100"; prefixLength = 24; }];
        defaultGateway = "10.0.20.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # Guest/untrusted node
    guest = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 4 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.30.100"; prefixLength = 24; }];
        defaultGateway = "10.0.30.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # Isolated node
    isolated = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 5 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.40.100"; prefixLength = 24; }];
        defaultGateway = "10.0.40.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # External attacker node
    attacker = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 1 ];
      networking = {
        useDHCP = false;
        enableIPv6 = false;
        interfaces.eth1.ipv4.addresses = [{ address = "203.0.113.100"; prefixLength = 24; }];
      };
      boot.kernel.sysctl = {
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };
  };

  testScript = ''
    start_all()

    # Wait for all nodes
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("nftables.service")

    mgmt.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.100'")
    trusted.wait_until_succeeds("ip addr show eth1 | grep '10.0.20.100'")
    guest.wait_until_succeeds("ip addr show eth1 | grep '10.0.30.100'")
    isolated.wait_until_succeeds("ip addr show eth1 | grep '10.0.40.100'")
    attacker.wait_until_succeeds("ip addr show eth1 | grep '203.0.113.100'")

    # Wait for DNS to be ready
    router.wait_until_succeeds("ss -tuln | grep ':53 '")

    # ======================================================================
    # INPUT CHAIN TESTS
    # ======================================================================

    # Test 1: management → router: full access
    print("Test 1: management -> router: full access")
    mgmt.succeed("timeout 5 nc -z -w 3 10.0.10.1 53")  # DNS
    mgmt.succeed("ping -c 1 -W 2 10.0.10.1")
    print("PASS")

    # Test 2: trusted → router: full access
    print("Test 2: trusted -> router: full access")
    trusted.succeed("timeout 5 nc -z -w 3 10.0.20.1 53")  # DNS
    trusted.succeed("ping -c 1 -W 2 10.0.20.1")
    print("PASS")

    # Test 3: untrusted → router: DNS/DHCP only
    print("Test 3: untrusted -> router: DNS/DHCP only")
    guest.succeed("timeout 5 nc -z -w 3 10.0.30.1 53")  # DNS allowed
    # SSH should be blocked (untrusted only gets DNS/DHCP via router services)
    guest.fail("timeout 3 nc -z -w 2 10.0.30.1 22")
    guest.fail("timeout 3 nc -z -w 2 10.0.30.1 80")
    print("PASS")

    # Test 4: isolated → router: nothing
    print("Test 4: isolated -> router: nothing (not even DNS)")
    isolated.fail("timeout 3 nc -z -w 2 10.0.40.1 53")  # DNS blocked
    isolated.fail("ping -c 1 -W 2 10.0.40.1")           # Ping blocked
    print("PASS")

    # Test 5: external → router: stealth
    print("Test 5: external -> router: stealth")
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 53")
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 22")
    attacker.fail("ping -c 1 -W 2 203.0.113.1")
    print("PASS")

    # Test 6: ICMP echo selective
    print("Test 6: ICMP echo - internal can ping, external/isolated cannot")
    mgmt.succeed("ping -c 1 -W 2 10.0.10.1")
    trusted.succeed("ping -c 1 -W 2 10.0.20.1")
    guest.succeed("ping -c 1 -W 2 10.0.30.1")
    isolated.fail("ping -c 1 -W 2 10.0.40.1")
    attacker.fail("ping -c 1 -W 2 203.0.113.1")
    print("PASS")

    # ======================================================================
    # FORWARD CHAIN TESTS
    # ======================================================================
    # Use ping for connectivity checks — it traverses the forward chain
    # without needing fragile background listener processes.

    # Test 7: management → trusted: allowed
    print("Test 7: management -> trusted: allowed")
    mgmt.succeed("ping -c 1 -W 2 10.0.20.100")
    print("PASS")

    # Test 8: management → untrusted: allowed
    print("Test 8: management -> untrusted: allowed")
    mgmt.succeed("ping -c 1 -W 2 10.0.30.100")
    print("PASS")

    # Test 9: management → external: allowed (via NAT)
    # We can't actually reach the internet, but we can verify the forward
    # chain allows the traffic by checking nftables rules
    print("Test 9: management -> external: allowed (verified via rules)")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth2.*oifname.*eth1.*accept'")
    print("PASS")

    # Test 10: trusted → management: allowed
    print("Test 10: trusted -> management: allowed")
    trusted.succeed("ping -c 1 -W 2 10.0.10.100")
    print("PASS")

    # Test 11: trusted → untrusted: allowed
    print("Test 11: trusted -> untrusted: allowed")
    trusted.succeed("ping -c 1 -W 2 10.0.30.100")
    print("PASS")

    # Test 12: trusted → external: allowed (verified via rules)
    print("Test 12: trusted -> external: allowed (verified via rules)")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth3.*oifname.*eth1.*accept'")
    print("PASS")

    # Test 13: untrusted → external: allowed (verified via rules)
    print("Test 13: untrusted -> external: allowed (verified via rules)")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth4.*oifname.*eth1.*accept'")
    print("PASS")

    # Test 14: untrusted → management: blocked
    print("Test 14: untrusted -> management: blocked")
    guest.fail("ping -c 1 -W 2 10.0.10.100")
    print("PASS")

    # Test 15: untrusted → trusted: blocked
    print("Test 15: untrusted -> trusted: blocked")
    guest.fail("ping -c 1 -W 2 10.0.20.100")
    print("PASS")

    # Test 16: isolated → anything: blocked
    print("Test 16: isolated -> anything: blocked")
    isolated.fail("ping -c 1 -W 2 10.0.10.100")
    isolated.fail("ping -c 1 -W 2 10.0.20.100")
    isolated.fail("ping -c 1 -W 2 10.0.30.100")
    print("PASS")

    # Test 17: external → internal: blocked
    print("Test 17: external -> internal: blocked")
    attacker.fail("ping -c 1 -W 2 10.0.10.100")
    attacker.fail("ping -c 1 -W 2 10.0.20.100")
    attacker.fail("ping -c 1 -W 2 10.0.30.100")
    print("PASS")

    # ======================================================================
    # Summary
    # ======================================================================
    print("")
    print("=" * 70)
    print("FIREWALL ZONE TESTS COMPLETE")
    print("=" * 70)
    print("All 17 tests passed.")
    print("=" * 70)
  '';
}
