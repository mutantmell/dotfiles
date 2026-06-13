# NixOS integration test for egress filtering
#
# Verifies that a default-drop nftables output chain correctly:
# 1. Allows traffic to explicitly permitted destinations/ports
# 2. Blocks traffic to non-permitted destinations
# 3. Always allows ICMP (ping)
# 4. Always allows loopback traffic
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  inherit ((import ../../lib/common {inherit lib;}).nftables) mkEgressFilter;
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "egress-filter";

    containers = {
      # DMZ host with egress filtering: allow DNS + HTTP to "allowed" node only
      dmzhost = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [1];
        networking = {
          useDHCP = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.10";
              prefixLength = 24;
            }
          ];
          nftables.enable = true;
          nftables.tables.egress = mkEgressFilter [
            "ip daddr 192.168.1.20 udp dport 53 accept"
            "ip daddr 192.168.1.20 tcp dport 53 accept"
            "ip daddr 192.168.1.20 tcp dport 80 accept"
          ];
        };

        environment.systemPackages = with pkgs; [curl netcat-gnu];
      };

      # Allowed destination — runs nginx
      allowed = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [1];
        networking = {
          useDHCP = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.20";
              prefixLength = 24;
            }
          ];
          firewall.allowedTCPPorts = [80];
        };

        services.nginx = {
          enable = true;
          virtualHosts.default = {
            default = true;
            locations."/".return = "200 'allowed'";
          };
        };
      };

      # Blocked destination — runs nginx but dmzhost should not be able to reach it
      blocked = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [1];
        networking = {
          useDHCP = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.30";
              prefixLength = 24;
            }
          ];
          firewall.allowedTCPPorts = [80];
        };

        services.nginx = {
          enable = true;
          virtualHosts.default = {
            default = true;
            locations."/".return = "200 'blocked'";
          };
        };
      };
    };

    testScript = ''
      start_all()

      # Wait for all nodes to be ready
      dmzhost.wait_for_unit("network.target")
      dmzhost.wait_for_unit("nftables.service")
      allowed.wait_for_unit("nginx.service")
      blocked.wait_for_unit("nginx.service")

      # Verify the egress table exists with policy drop
      print("Verify: egress table with output chain policy drop")
      dmzhost.succeed("nft list chain inet egress output | grep 'policy drop'")
      print("PASS")

      # ======================================================================
      # Test 1: Allowed destination (HTTP to allowed node) — succeeds
      # ======================================================================
      print("Test 1: HTTP to allowed destination succeeds")
      dmzhost.succeed("curl -sf --max-time 5 http://192.168.1.20")
      print("PASS")

      # ======================================================================
      # Test 2: Blocked destination (HTTP to blocked node) — fails
      # ======================================================================
      print("Test 2: HTTP to blocked destination fails")
      dmzhost.fail("curl -sf --max-time 5 http://192.168.1.30")
      print("PASS")

      # ======================================================================
      # Test 3: ICMP to both nodes — succeeds (always allowed)
      # ======================================================================
      print("Test 3: ICMP to allowed node succeeds")
      dmzhost.succeed("ping -c 1 -W 2 192.168.1.20")
      print("PASS")

      print("Test 4: ICMP to blocked node succeeds (ICMP always allowed)")
      dmzhost.succeed("ping -c 1 -W 2 192.168.1.30")
      print("PASS")

      # ======================================================================
      # Test 5: Loopback — succeeds
      # ======================================================================
      print("Test 5: Loopback traffic succeeds")
      dmzhost.succeed("ping -c 1 -W 2 127.0.0.1")
      print("PASS")

      # ======================================================================
      # Test 6: Arbitrary outbound port to allowed IP — blocked
      # ======================================================================
      print("Test 6: Non-allowed port to allowed IP is blocked")
      dmzhost.fail("timeout 3 nc -z -w 2 192.168.1.20 443")
      print("PASS")

      # ======================================================================
      # Summary
      # ======================================================================
      print("")
      print("=" * 70)
      print("EGRESS FILTER TESTS COMPLETE")
      print("=" * 70)
      print("All 6 tests passed.")
      print("=" * 70)
    '';
  }
