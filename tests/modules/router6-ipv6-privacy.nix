# NixOS integration test for IPv6 privacy extensions (SLAAC egress)
#
# Tests that a host with a static ULA address + IPv6AcceptRA + IPv6PrivacyExtensions
# gets both the stable ingress address and SLAAC temporary addresses for egress.
#
# Tests:
# 1. Client has the static ULA address (stable ingress)
# 2. Client has at least one SLAAC temporary address (privacy egress)
# 3. Client has at least two non-link-local IPv6 addresses
# 4. Client can ping router via the stable ULA address
# 5. The SLAAC address is in the correct /64 prefix
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-ipv6-privacy";

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

          # LAN interface with SLAAC (default mode)
          eth2 = {
            hardwareName = "eth2";
            network = {
              type = "static";
              addresses = ["10.0.10.1/24"];
              zone = "trusted";
              subnetId = 10;
              dhcp.enable = true;
              dhcp6 = {
                enable = true;
                dnsAddress = "fdc6:55f2:a5e:a::1";
              };
            };
          };
        };
      };

      # Test exercises IPv6 SLAAC + kresd — no DHCP probes (client has static addresses).
      services.kea.dhcp4.enable = lib.mkForce false;
      services.kea.dhcp6.enable = lib.mkForce false;
      # kea normally wants network-online.target; without it nothing pulls
      # up that target. Anchor it to multi-user.target so it still activates.
      systemd.targets.network-online.wantedBy = ["multi-user.target"];
    };

    # Client with static ULA + SLAAC privacy extensions (mirrors production config)
    client = {
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
            # Static ULA address (stable ingress) — same as production hosts
            Address = ["fdc6:55f2:a5e:a::42/64" "10.0.10.42/24"];
            IPv6AcceptRA = true;
            IPv6PrivacyExtensions = "yes";
            DHCP = "no";
          };
          routes = [
            {Gateway = "10.0.10.1";}
            {Gateway = "fdc6:55f2:a5e:a::1";}
          ];
        };
      };
    };
  };

  testScript = ''
    start_all()

    # Wait for router to be ready
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("kresd.target")

    # Wait for client networking
    client.wait_for_unit("systemd-networkd.service")

    # Test 1: Client has the static ULA address (stable ingress)
    client.succeed("ip -6 addr show eth1 | grep 'fdc6:55f2:a5e:a::42'")

    # Test 2: Client has at least one SLAAC temporary address (privacy egress)
    # Temporary addresses are flagged with "temporary" in ip addr output
    client.wait_until_succeeds(
        "ip -6 addr show eth1 | grep 'temporary'", timeout=60
    )

    # Test 3: Client has at least two non-link-local IPv6 addresses on the interface
    # (the static ULA + at least one SLAAC address)
    client.succeed(
        "test $(ip -6 addr show eth1 scope global | grep -c 'inet6') -ge 2"
    )

    # Test 4: Client can ping router via the stable ULA address
    client.succeed("ping -6 -c 3 fdc6:55f2:a5e:a::1")

    # Test 5: The SLAAC temporary address is in the correct /64 prefix
    client.succeed("ip -6 addr show eth1 | grep 'temporary' | grep 'fdc6:55f2:a5e:a:'")
  '';
}
