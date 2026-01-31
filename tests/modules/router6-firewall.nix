# NixOS integration test for router6 firewall stealth mode
#
# Verifies that the router operates in "stealth mode" for external networks:
# - TCP connections to closed ports are silently dropped (no RST)
# - UDP packets to closed ports are silently dropped (no ICMP unreachable)
# - Firewall policy is 'drop' not 'reject'
#
# Tests:
# 1. Verify firewall uses drop policy (not reject)
# 2. Verify external interface has explicit drop rule
# 3. TCP SYN to closed port is silently dropped (no response)
# 4. UDP to closed port is silently dropped (no ICMP unreachable)
# 5. Internal clients can still access router services

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

pkgs.nixosTest {
  name = "router6-firewall";

  nodes = {
    router = { config, pkgs, lib, ... }: {
      imports = [ ../../modules/router6 ];

      # Virtual network setup
      # - eth1 (vlan1) = WAN/external network (attacker connected here)
      # - eth2 (vlan2) = LAN/internal network (client connected here)
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
          # WAN interface (external/untrusted)
          eth1 = {
            hardwareName = "eth1";
            network = {
              type = "static";
              addresses = [ "192.168.1.1/24" ];
              trust = "external";
              nat.enable = true;
            };
          };

          # LAN interface (trusted)
          eth2 = {
            hardwareName = "eth2";
            network = {
              type = "static";
              addresses = [ "10.0.10.1/24" ];
              trust = "trusted";
              dhcp.enable = true;
            };
          };
        };

        # No custom firewall rules - testing default stealth behavior
        firewall = {
          extraInputRules = "";
          extraForwardRules = "";
        };
      };
    };

    # Attacker node on the external/WAN network
    attacker = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 1 ];

      networking = {
        useDHCP = false;
        interfaces.eth1 = {
          ipv4.addresses = [{
            address = "192.168.1.100";
            prefixLength = 24;
          }];
        };
        defaultGateway = "192.168.1.1";
      };

      environment.systemPackages = with pkgs; [
        netcat-gnu
        nmap
        tcpdump
      ];
    };

    # Client node on the internal/LAN network
    client = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 2 ];

      networking = {
        useDHCP = false;
        interfaces.eth1 = {
          ipv4.addresses = [{
            address = "10.0.10.100";
            prefixLength = 24;
          }];
        };
        defaultGateway = "10.0.10.1";
        nameservers = [ "10.0.10.1" ];
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
    attacker.wait_for_unit("network-online.target")
    client.wait_for_unit("network-online.target")

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
    # Test 2: Verify external interface has explicit drop rule
    # ==========================================================================
    print("Test 2: Checking external interface drop rule...")

    # The firewall should have an explicit drop rule for external interface
    router.succeed("nft list chain inet filter input | grep 'iifname.*eth1.*drop'")

    print("PASS: External interface has explicit drop rule")

    # ==========================================================================
    # Test 3: TCP SYN to closed port is silently dropped (stealth mode)
    # ==========================================================================
    print("Test 3: Testing TCP stealth mode from external network...")

    # Start tcpdump on attacker to capture any RST responses
    attacker.execute("tcpdump -i eth1 -c 5 'tcp[tcpflags] & tcp-rst != 0' -w /tmp/rst.pcap &")
    attacker.execute("sleep 1")

    # Attempt TCP connection to a closed port (8888) on the router
    # This should timeout with no response (stealth mode)
    # Use a short timeout to avoid waiting too long
    attacker.fail("timeout 3 nc -z -w 2 192.168.1.1 8888")

    # Wait a moment for any delayed RST packets
    attacker.execute("sleep 2")

    # Kill tcpdump
    attacker.execute("pkill tcpdump || true")
    attacker.execute("sleep 1")

    # Check that no RST packets were captured
    # If the file has only the pcap header (24 bytes), no packets were captured
    rst_count = attacker.succeed("tcpdump -r /tmp/rst.pcap 2>/dev/null | wc -l || echo 0").strip()
    assert rst_count == "0", f"Expected 0 RST packets but got {rst_count} - router is not in stealth mode!"

    print("PASS: TCP connection silently dropped (no RST response)")

    # ==========================================================================
    # Test 4: UDP to closed port is silently dropped (no ICMP unreachable)
    # ==========================================================================
    print("Test 4: Testing UDP stealth mode from external network...")

    # Start tcpdump to capture ICMP port unreachable messages
    attacker.execute("tcpdump -i eth1 -c 5 'icmp[icmptype] == 3' -w /tmp/icmp.pcap &")
    attacker.execute("sleep 1")

    # Send UDP packet to a closed port (9999) on the router
    attacker.execute("echo 'test' | nc -u -w 1 192.168.1.1 9999 || true")

    # Wait for any ICMP response
    attacker.execute("sleep 2")

    # Kill tcpdump
    attacker.execute("pkill tcpdump || true")
    attacker.execute("sleep 1")

    # Check that no ICMP port unreachable packets were captured
    icmp_count = attacker.succeed("tcpdump -r /tmp/icmp.pcap 2>/dev/null | wc -l || echo 0").strip()
    assert icmp_count == "0", f"Expected 0 ICMP unreachable but got {icmp_count} - router is not in stealth mode!"

    print("PASS: UDP packet silently dropped (no ICMP unreachable)")

    # ==========================================================================
    # Test 5: Verify attacker cannot access router services
    # ==========================================================================
    print("Test 5: Verifying external network cannot access router services...")

    # Attacker should not be able to access DNS on the router
    attacker.fail("timeout 3 nc -z -w 2 192.168.1.1 53")

    # Attacker should not be able to access any common service ports
    attacker.fail("timeout 3 nc -z -w 2 192.168.1.1 22")  # SSH
    attacker.fail("timeout 3 nc -z -w 2 192.168.1.1 80")  # HTTP
    attacker.fail("timeout 3 nc -z -w 2 192.168.1.1 443") # HTTPS

    print("PASS: External network blocked from router services")

    # ==========================================================================
    # Test 6: Verify internal clients CAN access router services
    # ==========================================================================
    print("Test 6: Verifying internal network can access router services...")

    # Wait for kresd to be ready
    router.wait_for_unit("kresd.service")

    # Client should be able to access DNS
    client.succeed("timeout 5 nc -z -w 3 10.0.10.1 53")

    # Client should be able to query DNS
    client.succeed("${pkgs.dig}/bin/dig @10.0.10.1 localhost +short +timeout=5")

    print("PASS: Internal network can access router services")

    # ==========================================================================
    # Test 7: Verify nftables ruleset structure
    # ==========================================================================
    print("Test 7: Verifying nftables ruleset structure...")

    # Should have inet filter table
    router.succeed("nft list tables | grep 'inet filter'")

    # Should have connection tracking for established connections
    router.succeed("nft list chain inet filter input | grep 'ct state established,related accept'")

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
    print("- No ICMP unreachable or TCP RST responses leak router presence")
    print("- Internal clients retain full access to router services")
    print("=" * 70)
  '';
}
