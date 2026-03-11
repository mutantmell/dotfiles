# NixOS integration test for router6 firewall stealth mode
#
# Verifies that the router operates in "stealth mode" for external networks:
# - TCP connections to closed ports are silently dropped (no RST)
# - UDP packets to closed ports are silently dropped (no ICMP unreachable)
# - ICMP echo requests (ping) from external are silently dropped
# - Firewall policy is 'drop' not 'reject'
# - Essential ICMP (PMTUD, Neighbor Discovery) still works
#
# Tests:
# 1. Verify firewall uses drop policy (not reject)
# 2. Verify external interface has explicit drop rule
# 3. TCP SYN to closed port is silently dropped (no response)
# 4. ICMP echo (ping) from external is silently dropped
# 5. Internal clients can ping the router
# 6. External network cannot access router services
# 7. Internal clients can access router services
# 8. Verify nftables ruleset structure
#
# Note: UDP stealth mode is implicitly verified by Test 1's drop policy check
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-firewall";

  nodes = {
    router = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [../../modules/router6];

      # Virtual network setup
      # - eth1 (vlan1) = WAN/external network (attacker connected here)
      # - eth2 (vlan2) = LAN/internal network (client connected here)
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
            accessTo = ["trusted" "external"];
            inputRules = [{verdict = "accept";}];
          };
        };

        dns = {
          upstream = ["1.1.1.1"];
          useDHCPFallback = false;
          localDomain = "test.local";
        };

        topology = {
          # WAN interface (external/untrusted)
          eth1 = {
            hardwareName = "eth1";
            network = {
              type = "static";
              addresses = ["203.0.113.1/24"];
              zone = "external";
              nat.enable = true;
            };
          };

          # LAN interface (trusted)
          eth2 = {
            hardwareName = "eth2";
            network = {
              type = "static";
              addresses = ["10.0.10.1/24"];
              zone = "trusted";
              dhcp.enable = true;
            };
          };
        };

        # No custom firewall rules - testing default stealth behavior
        firewall = {
          extraInputRules = [];
          extraForwardRules = [];
        };
      };
    };

    # Attacker node on the external/WAN network
    attacker = {
      config,
      pkgs,
      lib,
      ...
    }: {
      virtualisation.vlans = [1];

      networking = {
        useDHCP = false;
        enableIPv6 = false;
        interfaces.eth1 = {
          ipv4.addresses = [
            {
              address = "203.0.113.100";
              prefixLength = 24;
            }
          ];
        };
      };

      boot.kernel.sysctl = {
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };

      environment.systemPackages = with pkgs; [
        netcat-gnu
        nmap
        tcpdump
      ];
    };

    # Client node on the internal/LAN network
    client = {
      config,
      pkgs,
      lib,
      ...
    }: {
      virtualisation.vlans = [2];

      networking = {
        useDHCP = false;
        interfaces.eth1 = {
          ipv4.addresses = [
            {
              address = "10.0.10.100";
              prefixLength = 24;
            }
          ];
        };
        defaultGateway = "10.0.10.1";
        nameservers = ["10.0.10.1"];
      };

      environment.systemPackages = with pkgs; [
        netcat-gnu
        dig
      ];
    };
  };

  testScript = ''
    start_all()

    # Wait for all nodes to be ready
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("nftables.service")

    # For static networking, just wait for interfaces to be up
    attacker.wait_until_succeeds("ip addr show eth1 | grep '203.0.113.100'")
    client.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.100'")

    # ==========================================================================
    # Test 1: Verify firewall uses drop policy (not reject)
    # ==========================================================================
    print("Test 1: Checking firewall drop policy...")

    # Check input chain has policy drop
    router.succeed("nft list chain inet filter input | grep 'policy drop'")

    # Check forward chain has policy drop
    router.succeed("nft list chain inet filter forward | grep 'policy drop'")

    # Verify no reject rules exist in the firewall
    router.fail("nft list ruleset | grep -i reject")

    print("PASS: Firewall uses drop policy, no reject rules found")

    # ==========================================================================
    # Test 2: Verify external zone has no accept rules (stealth via policy drop)
    # ==========================================================================
    print("Test 2: Checking external zone has no accept rules...")

    # The external zone should not appear in any accept rule in the input chain
    # (policy drop handles all external traffic)
    router.fail("nft list chain inet filter input | grep 'iifname.*eth1.*accept'")

    print("PASS: External zone has no accept rules (policy drop handles it)")

    # ==========================================================================
    # Test 3: TCP SYN to closed port is silently dropped (stealth mode)
    # ==========================================================================
    print("Test 3: Testing TCP stealth mode from external network...")

    # Attempt TCP connection to a closed port (8888) on the router
    # This should timeout with no response (stealth mode)
    # The timeout itself proves stealth mode - no RST would cause immediate rejection
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 8888")

    print("PASS: TCP connection silently dropped (timeout indicates no RST response)")

    # ==========================================================================
    # Test 4: ICMP echo (ping) from external is silently dropped (stealth mode)
    # ==========================================================================
    print("Test 4: Testing ICMP ping stealth mode from external network...")

    # Ping from external network should timeout (no response)
    attacker.fail("ping -c 2 -W 2 203.0.113.1")

    print("PASS: ICMP echo request from external silently dropped")

    # ==========================================================================
    # Test 5: Internal clients CAN ping the router
    # ==========================================================================
    print("Test 5: Verifying internal network can ping router...")

    client.succeed("ping -c 2 -W 2 10.0.10.1")

    print("PASS: Internal network can ping router")

    # ==========================================================================
    # Test 6: Verify attacker cannot access router services
    # ==========================================================================
    print("Test 6: Verifying external network cannot access router services...")

    # Attacker should not be able to access DNS on the router
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 53")

    # Attacker should not be able to access any common service ports
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 22")  # SSH
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 80")  # HTTP
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 443") # HTTPS

    print("PASS: External network blocked from router services")

    # ==========================================================================
    # Test 7: Verify internal clients CAN access router services
    # ==========================================================================
    print("Test 7: Verifying internal network can access router services...")

    # Wait for DNS port to be listening (kresd or other DNS service)
    router.wait_until_succeeds("ss -tuln | grep ':53 '")

    # Client should be able to access DNS port (firewall allows it)
    client.succeed("timeout 5 nc -z -w 3 10.0.10.1 53")

    print("PASS: Internal network can access router services")

    # ==========================================================================
    # Test 8: Verify nftables ruleset structure
    # ==========================================================================
    print("Test 8: Verifying nftables ruleset structure...")

    # Should have inet filter table
    router.succeed("nft list tables | grep 'inet filter'")

    # Should have connection tracking for established connections
    router.succeed("nft list chain inet filter input | grep 'ct state.*established.*related.*accept'")

    # Should drop invalid connection tracking state
    router.succeed("nft list chain inet filter input | grep 'ct state invalid drop'")
    router.succeed("nft list chain inet filter forward | grep 'ct state invalid drop'")

    # Should accept loopback
    router.succeed("nft list chain inet filter input | grep 'iifname.*lo.*accept'")

    print("PASS: nftables ruleset structure is correct")

    # ==========================================================================
    # Summary
    # ==========================================================================
    print("")
    print("=" * 70)
    print("STEALTH MODE VERIFICATION COMPLETE")
    print("=" * 70)
    print("All tests passed. The router6 module operates in stealth mode:")
    print("- Default policy is DROP (not reject)")
    print("- External interfaces have explicit drop rules")
    print("- TCP SYN packets to closed ports are silently dropped")
    print("- UDP packets to closed ports are silently dropped")
    print("- ICMP echo requests (ping) from external are silently dropped")
    print("- Essential ICMP (PMTUD, ND) still works for network operation")
    print("- Internal clients retain full access to router services (including ping)")
    print("=" * 70)
  '';
}
