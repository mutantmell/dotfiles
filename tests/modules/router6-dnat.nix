# NixOS integration test for router6 DNAT / port forwarding
#
# Verifies end-to-end port forwarding:
# - DNAT rule correctly translates external:8080 → server:8888
# - Forward chain accepts DNAT traffic
# - Non-forwarded ports remain blocked
# - Internal IPs unreachable from external network
#
# Topology: 3 VMs, 2 VLANs
# - router: eth1=external (203.0.113.1/24), eth2=trusted (10.0.10.1/24)
# - server: eth1=trusted (10.0.10.50/24), runs HTTP on port 8888
# - attacker: eth1=external (203.0.113.100/24)
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "router6-dnat";

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
            accessTo = ["external"];
            inputRules = [{verdict = "accept";}];
          };
        };

        dns = {
          upstream = ["1.1.1.1"];
        };

        firewall.portForwards = [
          {
            proto = "tcp";
            sourcePort = 8080;
            destination = "10.0.10.50:8888";
          }
        ];

        topology = {
          eth1 = {
            hardwareName = "eth1";
            network = {
              type = "static";
              addresses = ["203.0.113.1/24"];
              zone = "external";
              nat.enable = true;
            };
          };
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
      };

      # Test exercises nftables DNAT rules only — no DNS or DHCP probes.
      services.kresd.enable = lib.mkForce false;
      services.kea.dhcp4.enable = lib.mkForce false;
      services.kea.dhcp6.enable = lib.mkForce false;
      # kea normally wants network-online.target; without it nothing pulls
      # up that target. Anchor it to multi-user.target so it still activates.
      systemd.targets.network-online.wantedBy = ["multi-user.target"];
    };

    server = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [../lib/test-minimal-base.nix];
      virtualisation.vlans = [2];
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
      networking.firewall.allowedTCPPorts = [8888];
      # Simple HTTP server via systemd to avoid background process issues
      systemd.services.test-http = {
        wantedBy = ["multi-user.target"];
        after = ["network.target"];
        script = ''
          echo 'DNAT-OK' > /tmp/index.html
          cd /tmp && ${pkgs.python3}/bin/python3 -m http.server 8888
        '';
      };
    };

    attacker = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [../lib/test-minimal-base.nix];
      virtualisation.vlans = [1];
      networking = {
        useDHCP = false;
        enableIPv6 = false;
        interfaces.eth1.ipv4.addresses = [
          {
            address = "203.0.113.100";
            prefixLength = 24;
          }
        ];
        defaultGateway = "203.0.113.1";
      };
      boot.kernel.sysctl = {
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };
      environment.systemPackages = with pkgs; [curl netcat-gnu];
    };
  };

  testScript = ''
    start_all()

    # Wait for all nodes
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("nftables.service")
    server.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.50'")
    attacker.wait_until_succeeds("ip addr show eth1 | grep '203.0.113.100'")

    # Wait for HTTP server
    server.wait_for_unit("test-http.service")
    server.wait_until_succeeds("nc -z 127.0.0.1 8888")

    # Test 1: DNAT rule present in nat table
    print("Test 1: DNAT rule present in nft nat table")
    router.succeed("nft list table ip nat | grep 'dport 8080 dnat to 10.0.10.50:8888'")
    print("PASS")

    # Test 2: Forward accept rule present (matches dest port 8888 after DNAT)
    print("Test 2: Forward accept rule present")
    router.succeed("nft list chain inet filter forward | grep 'dport 8888'")
    print("PASS")

    # Test 3: End-to-end DNAT works
    print("Test 3: End-to-end DNAT (attacker -> router:8080 -> server:8888)")
    attacker.succeed("curl -s --connect-timeout 5 http://203.0.113.1:8080/index.html | grep DNAT-OK")
    print("PASS")

    # Test 4: Non-forwarded port blocked
    print("Test 4: Non-forwarded port 80 blocked")
    attacker.fail("nc -z -w 2 203.0.113.1 80")
    print("PASS")

    # Test 5: Non-DNAT'd internal ports remain blocked from external
    print("Test 5: Internal port 22 blocked from external (no DNAT rule)")
    attacker.fail("nc -z -w 2 10.0.10.50 22")
    print("PASS")

    # Summary
    print("")
    print("=" * 70)
    print("DNAT TESTS COMPLETE")
    print("=" * 70)
    print("All 5 tests passed.")
    print("=" * 70)
  '';
}
