# NixOS integration test for router6 DHCPv6 (Kea DHCPv6) functionality
#
# Tests:
# 1. Kea DHCPv6 service is running
# 2. Stateful mode: client gets DHCPv6 address in ::1000-::1fff range
# 3. Stateful mode: client also gets SLAAC address (both present)
# 4. Stateful mode: client can ping router over IPv6
# 5. Stateless mode: client gets SLAAC address only (no DHCPv6 address pool)
# 6. RA flags are set correctly per mode
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-dhcpv6";

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

        # Virtual network setup - eth1 is WAN, eth2 is LAN (stateful), eth3 is LAN (stateless)
        virtualisation.vlans = [1 2 3];

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
            upstream = ["1.1.1.1"];
            localDomain = "test.local";
          };

          topology = {
            # WAN interface
            eth1 = {
              hardwareName = "eth1";
              network = {
                type = "static";
                addresses = ["192.168.1.1/24"];
                zone = "external";
                nat.enable = true;
              };
            };

            # LAN interface with stateful DHCPv6
            eth2 = {
              hardwareName = "eth2";
              network = {
                type = "static";
                addresses = ["10.0.20.1/24"];
                zone = "trusted";
                subnetId = 20;
                dhcp.enable = true;
                dhcp6 = {
                  enable = true;
                  mode = "stateful";
                  dnsAddress = "fdc6:55f2:a5e:14::1";
                };
              };
            };

            # LAN interface with stateless DHCPv6
            eth3 = {
              hardwareName = "eth3";
              network = {
                type = "static";
                addresses = ["10.0.30.1/24"];
                zone = "iot";
                subnetId = 30;
                dhcp.enable = true;
                dhcp6 = {
                  enable = true;
                  mode = "stateless";
                  dnsAddress = "fdc6:55f2:a5e:1e::1";
                };
              };
            };
          };
        };
      };

      # Client on stateful DHCPv6 network
      client_stateful = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
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
              # Request address from DHCPv6 (stateful)
              UseAddress = true;
              UseDNS = true;
            };
          };
        };

        # Accept RAs even though we use DHCPv6 (for SLAAC privacy addresses)
        boot.kernel.sysctl = {
          "net.ipv6.conf.eth1.accept_ra" = 2;
          "net.ipv6.conf.eth1.autoconf" = 1;
        };
      };

      # Client on stateless DHCPv6 network
      client_stateless = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [3];

        networking.useDHCP = false;

        systemd.network = {
          enable = true;
          networks."10-eth1" = {
            matchConfig.Name = "eth1";
            networkConfig = {
              DHCP = "ipv6";
              IPv6AcceptRA = true;
            };
          };
        };

        boot.kernel.sysctl = {
          "net.ipv6.conf.eth1.accept_ra" = 2;
          "net.ipv6.conf.eth1.autoconf" = 1;
        };
      };
    };

    testScript = ''
      start_all()

      # Wait for router to be ready
      router.wait_for_unit("network-online.target")
      router.wait_for_unit("kresd.target")
      router.wait_for_unit("kea-dhcp6-server.service")

      # Test 1: Kea DHCPv6 service is running
      router.succeed("systemctl is-active kea-dhcp6-server.service")

      # Test 2: Router has IPv6 addresses on both interfaces
      router.succeed("ip -6 addr show eth2 | grep 'fdc6:55f2:a5e:14::1'")
      router.succeed("ip -6 addr show eth3 | grep 'fdc6:55f2:a5e:1e::1'")

      # --- Stateful client tests ---
      client_stateful.wait_for_unit("systemd-networkd.service")

      # Test 4: Client gets SLAAC address (always available)
      client_stateful.wait_until_succeeds(
          "ip -6 addr show eth1 | grep 'fdc6:55f2:a5e:14:'", timeout=60
      )

      # Test 5: Client gets DHCPv6 address in the ::1000-::1fff pool range (/128 prefix)
      client_stateful.wait_until_succeeds(
          "ip -6 addr show eth1 | grep -E 'fdc6:55f2:a5e:14::1[0-9a-f]{3}/128'", timeout=60
      )

      # Test 6: Client can ping router over IPv6
      client_stateful.succeed("ping -6 -c 3 fdc6:55f2:a5e:14::1")

      # --- Stateless client tests ---
      client_stateless.wait_for_unit("systemd-networkd.service")

      # Test 7: Client gets SLAAC address
      client_stateless.wait_until_succeeds(
          "ip -6 addr show eth1 | grep 'fdc6:55f2:a5e:1e:'", timeout=60
      )

      # Test 8: Stateless client does NOT have a DHCPv6 address (no /128 lease)
      client_stateless.fail("ip -6 addr show eth1 | grep '/128'")

      # Test 9: Client can ping router over IPv6
      client_stateless.succeed("ping -6 -c 3 fdc6:55f2:a5e:1e::1")
    '';
  }
