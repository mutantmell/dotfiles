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
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-ipv6";

    containers = {
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

        # Virtual network setup - eth1 is WAN, eth2 is LAN
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
            localDomain = "test.local";
          };

          topology = {
            # WAN interface (external)
            eth1 = {
              hardwareName = "eth1";
              network = {
                type = "static";
                addresses = ["192.168.1.1/24"];
                zone = "external";
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
                    addresses = ["10.0.10.1/24"];
                    zone = "trusted";
                    dhcp.enable = true;
                    dhcp6 = {
                      enable = true;
                      dnsAddress = "fdc6:55f2:a5e:a::1";
                    };
                  };
                };
              };
            };
          };
        };

        # Test exercises kresd + kea-dhcp4 (DHCP client on vlan10) — no stateful DHCPv6 probes.
        services.kea.dhcp6.enable = lib.mkForce false;
      };

      client = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [2];

        # Use traditional networking with VLAN
        networking.useDHCP = false;
        networking.dhcpcd.enable = true;
        networking.vlans.vlan10 = {
          id = 10;
          interface = "eth1";
        };
        networking.interfaces.vlan10.useDHCP = true;

        # Enable IPv6 Router Advertisement acceptance
        boot.kernel.sysctl = {
          "net.ipv6.conf.vlan10.accept_ra" = 2;
          "net.ipv6.conf.vlan10.autoconf" = 1;
        };
      };
    };

    testScript = ''
      start_all()

      # Wait for router to be ready
      router.wait_for_unit("network-online.target")
      router.wait_for_unit("kresd.target")

      # Test 1: Verify IPv6 forwarding is enabled
      router.succeed("sysctl net.ipv6.conf.all.forwarding | grep '= 1'")

      # Test 2: Verify router has auto-generated IPv6 address on VLAN
      # VLAN 10 -> fdc6:55f2:a5e:a::1/64 (kernel normalizes 0a5e to a5e)
      # wait-online is disabled for routers, so vlan10 may still be configuring
      router.wait_until_succeeds("ip -6 addr show vlan10 | grep 'fdc6:55f2:a5e:a::1'", timeout=30)

      # Test 3: Verify Router Advertisements are configured
      # Check that IPv6SendRA is enabled in networkd
      router.succeed("networkctl status vlan10 | grep -i 'IPv6'")

      # Test 4: Verify nftables has IPv6 rules
      router.succeed("nft list ruleset | grep 'icmpv6 type'")
      router.succeed("nft list ruleset | grep 'table ip6 nat'")

      # Test 5: Verify kresd is listening on IPv6
      router.succeed("ss -6 -tulnp | grep ':53'")
      # Check kresd is listening on the router's IPv6 address
      router.succeed("ss -tulnp | grep 'fdc6:55f2:a5e:a::1'")

      # Client tests
      client.wait_for_unit("dhcpcd.service")

      # Wait for VLAN to come up
      client.wait_until_succeeds("ip link show vlan10 | grep 'state UP'", timeout=30)

      # Test 6: Client receives IPv6 via SLAAC
      # Wait for client to get an IPv6 address in the ULA range
      client.wait_until_succeeds("ip -6 addr show vlan10 | grep 'fdc6:55f2:a5e:a:'", timeout=60)

      # Test 7: Client can ping router over IPv6
      client.succeed("ping -6 -c 3 fdc6:55f2:a5e:a::1")

      # Test 8: Client can reach DNS over IPv6
      client.wait_until_succeeds("${pkgs.dig}/bin/dig @fdc6:55f2:a5e:a::1 -6 . NS +norecurse +time=2 +tries=1 | grep -F 'SERVER: fdc6:55f2:a5e:a::1#53'", timeout=30)
    '';
  }
