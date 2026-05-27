# NixOS integration test for router6 DNS interception
#
# Verifies DNS interception DNAT rule generation at runtime:
# - DNAT rules present in nft listing (UDP + TCP, both address families)
# - Upstream DNS excluded from interception
# - Router addresses excluded from DNAT destination
# - kresd listens on DNS-serving interfaces
#
# Topology: 2 VMs, 1 VLAN
# - router: eth1=lan (VLAN 1, 10.0.10.1/24) with DNS interception enabled
# - client: eth1=lan (VLAN 1, 10.0.10.50/24)
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-dns-interception";

  nodes = {
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

      virtualisation.vlans = [1];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        zones = {
          trusted = {
            icmpEcho = "enable";
            accessTo = [];
            inputRules = [{verdict = "accept";}];
          };
        };

        dns = {
          upstream = ["10.0.20.2"];
          interception = {
            enable = true;
            target = "10.0.10.1";
            target6 = "fdc6:55f2:0a5e:a::1";
          };
        };

        topology = {
          eth1 = {
            hardwareName = "eth1";
            network = {
              type = "static";
              addresses = ["10.0.10.1/24"];
              zone = "trusted";
              dhcp.enable = true;
              subnetId = 10;
            };
          };
        };
      };
    };

    client = {
      config,
      pkgs,
      ...
    }: {
      imports = [../lib/test-minimal-base.nix];
      virtualisation.vlans = [1];
      networking = {
        useDHCP = false;
        enableIPv6 = false;
        interfaces.eth1.ipv4.addresses = [
          {
            address = "10.0.10.50";
            prefixLength = 24;
          }
        ];
        defaultGateway = "10.0.10.1";
      };
    };
  };

  testScript = ''
    start_all()

    # Wait for router
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("nftables.service")
    router.wait_for_unit("kresd@1.service")
    client.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.50'")

    # Test 1: IPv4 DNAT rules present
    print("Test 1: IPv4 DNS interception DNAT rules present")
    router.succeed("nft list table ip nat | grep 'udp dport 53 dnat to 10.0.10.1:53'")
    router.succeed("nft list table ip nat | grep 'tcp dport 53 dnat to 10.0.10.1:53'")
    print("PASS")

    # Test 2: IPv6 DNAT rules present
    print("Test 2: IPv6 DNS interception DNAT rules present")
    router.succeed("nft list table ip6 nat | grep 'udp dport 53 dnat to'")
    router.succeed("nft list table ip6 nat | grep 'tcp dport 53 dnat to'")
    print("PASS")

    # Test 3: Upstream DNS (10.0.20.2) is excluded from source interception
    print("Test 3: Upstream exclusion in DNAT rules")
    router.succeed("nft list table ip nat | grep 'saddr != 10.0.20.2'")
    print("PASS")

    # Test 4: Router's own IPs excluded from DNAT destination
    print("Test 4: Router IP excluded from DNAT destination")
    router.succeed("nft list table ip nat | grep 'daddr !=.*10.0.10.1'")
    print("PASS")

    # Test 5: Client can reach router's kresd directly (port open)
    print("Test 5: Client can reach kresd on router")
    client.succeed("nc -z -w 2 10.0.10.1 53")
    print("PASS")

    # Summary
    print("")
    print("=" * 70)
    print("DNS INTERCEPTION TESTS COMPLETE - All 5 tests passed")
    print("=" * 70)
  '';
}
