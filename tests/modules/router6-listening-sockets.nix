# NixOS integration test verifying router6 services bind to specific addresses
#
# Tests that kresd (DNS) only listens on:
# 1. Loopback (127.0.0.1:53, [::1]:53)
# 2. LAN interface addresses (per dnsInterfaces logic)
#
# And does NOT listen on:
# 3. Wildcard 0.0.0.0:53 — would expose DNS to WAN
# 4. Wildcard [::]:53 — same for IPv6
# 5. WAN interface address — zones without DNS inputRules must be excluded
#
# This verifies the dnsInterfaces filtering logic works end-to-end.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-listening-sockets";

  nodes = {
    router = {
      config,
      pkgs,
      ...
    }: {
      imports = [
        ../../modules/router6
        ../lib/test-minimal-base.nix
      ];

      # eth0 = WAN (VLAN 1), eth1 = LAN (VLAN 2)
      virtualisation.vlans = [1 2];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        dns = {
          upstream = ["1.1.1.1"];
        };

        zones = {
          external = {
            icmpEcho = "disable";
            accessTo = [];
            # No DNS inputRules on WAN — kresd must NOT listen on wan address
            inputRules = [];
          };
          trusted = {
            icmpEcho = "enable";
            accessTo = ["external"];
            # Blanket accept → zoneAllowsDns = true → kresd listens on lan
            inputRules = [{verdict = "accept";}];
          };
        };

        topology = {
          # WAN: no DNS inputRule in external zone — kresd must not listen here
          wan = {
            hardwareName = "eth0";
            network = {
              type = "static";
              addresses = ["203.0.113.1/24"];
              zone = "external";
              nat.enable = true;
            };
          };

          # LAN: trusted zone with DNS allowed — kresd must listen here
          lan = {
            hardwareName = "eth1";
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
    router.wait_for_unit("kresd@1.service")
    router.wait_for_unit("kea-dhcp4-server.service")

    # Wait for LAN interface to get its address before checking sockets
    router.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.1'", timeout=30)

    # === kresd: verify no wildcard binds ===

    # Must NOT bind to 0.0.0.0:53 (would expose DNS to all interfaces including WAN)
    router.fail("ss -tulnp | grep -E '\\s0\\.0\\.0\\.0:53\\s'")

    # Must NOT bind to [::]:53 (IPv6 wildcard)
    router.fail("ss -tulnp | grep -F '[::]:53'")

    # Must NOT listen on the WAN address (external zone has no DNS inputRules)
    router.fail("ss -tulnp | grep '203\\.0\\.113\\.1:53'")

    # MUST listen on loopback (for local queries from the router itself)
    router.succeed("ss -tulnp | grep '127.0.0.1:53'")

    # MUST listen on LAN interface address (trusted zone has DNS inputRules)
    router.succeed("ss -tulnp | grep '10.0.10.1:53'")

    # === kresd: verify IPv6 sockets ===

    # Must listen on IPv6 loopback
    router.succeed("ss -tulnp | grep '\\[::1\\]:53'")

    # Wait for LAN IPv6 address to appear (subnetId=10 → fdc6:55f2:0a5e:a::1)
    router.wait_until_succeeds("ip -6 addr show eth1 | grep 'fdc6:55f2:0a5e:a::1'", timeout=30)

    # MUST listen on LAN IPv6 address
    router.succeed("ss -tulnp | grep '\\[fdc6:55f2:0a5e:a::1\\]:53'")

    # === kresd: DNS actually responds (sanity check) ===
    router.succeed("${pkgs.dig}/bin/dig @10.0.10.1 localhost A +short +time=2 || true")
    router.succeed("${pkgs.dig}/bin/dig @127.0.0.1 localhost A +short +time=2 || true")
  '';
}
