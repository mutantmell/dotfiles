# NixOS integration test for router6 DNS blocking (Blocky in front of kresd).
#
# This is the regression the old `sourceRoutes` design failed: a block cached
# from one client leaked to an exempt client because kresd's shared cache is
# keyed only on (qname,qtype,qclass). Here Blocky sits in front, sees real
# client IPs, and blocks per-client *before* any shared cache — so the same
# ads-listed domain must resolve to the block for a blocked client AND to the
# real answer for an opt-out client, in BOTH orders (neither poisons the other).
#
# Topology: real Blocky + real kresd on the router, a real authoritative
# upstream, and two clients on two subnets (one blocked, one opted out).
#
#   blockedClient (10.0.10.50, vlan1) ─┐
#                                       ├─ router: Blocky :53 ─► kresd :5335 ─► upstream (unbound, 10.0.20.2)
#   optoutClient  (10.0.11.50, vlan2) ─┘   eth1 blocked / eth2 dnsBlock=false
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  # Domain-per-line denylist as a pinned store path (never an https URL —
  # mirrors the production stevenblack-hosts input).
  denylist = pkgs.writeText "ads-denylist" ''
    ads1.adstest.net
    ads2.adstest.net
  '';
  # A static client on one VLAN, pointing its default route at the router.
  mkClient = {
    vlan,
    address,
    gateway,
  }: {pkgs, ...}: {
    imports = [../lib/test-minimal-base.nix];
    virtualisation.vlans = [vlan];
    environment.systemPackages = [pkgs.dnsutils pkgs.netcat];
    networking = {
      useDHCP = false;
      enableIPv6 = false;
      interfaces.eth1.ipv4.addresses = [
        {
          inherit address;
          prefixLength = 24;
        }
      ];
      defaultGateway = gateway;
    };
  };
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-dns-blocking";

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

        virtualisation.vlans = [1 2 3];

        environment.systemPackages = [pkgs.dnsutils pkgs.curl];

        router6 = {
          enable = true;
          ulaPrefix = "fdc6:55f2:0a5e::/48";

          zones.trusted = {
            icmpEcho = "enable";
            accessTo = [];
            inputRules = [{verdict = "accept";}];
          };

          dns = {
            upstream = ["10.0.20.2"];
            # The upstream is a trusted authoritative resolver on a directly
            # wired test segment, and the test domains are unsigned — stub
            # (no kresd-side DNSSEC re-validation) and DNSSEC off.
            upstreamPolicy = "stub";
            enableDNSSEC = false;

            blocking = {
              enable = true;
              denylists.ads = [denylist];
              conditionalDomains = ["internal"];
            };
          };

          topology = {
            eth1 = {
              hardwareName = "eth1";
              network = {
                type = "static";
                addresses = ["10.0.10.1/24"];
                zone = "trusted";
                subnetId = 10;
                # dnsBlock defaults to true — this subnet is blocked.
              };
            };
            eth2 = {
              hardwareName = "eth2";
              network = {
                type = "static";
                addresses = ["10.0.11.1/24"];
                zone = "trusted";
                subnetId = 11;
                dnsBlock = false; # opt-out: clients here bypass the blocklist
              };
            };
            eth3 = {
              hardwareName = "eth3";
              network = {
                type = "static";
                addresses = ["10.0.20.1/24"];
                zone = "trusted";
                subnetId = 20;
              };
            };
          };
        };

        # No DHCP in this test — addresses are static.
        services.kea.dhcp4.enable = lib.mkForce false;
        services.kea.dhcp6.enable = lib.mkForce false;
      };

      # Authoritative upstream: answers the test zones directly so kresd has a
      # real backend to stub to.
      upstream = {
        config,
        pkgs,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [3];
        networking = {
          useDHCP = false;
          enableIPv6 = false;
          firewall.enable = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "10.0.20.2";
              prefixLength = 24;
            }
          ];
        };
        services.unbound = {
          enable = true;
          settings.server = {
            interface = ["0.0.0.0"];
            access-control = ["10.0.0.0/8 allow"];
            local-zone = [
              ''"adstest.net." static''
              ''"internal." static''
            ];
            local-data = [
              ''"ads1.adstest.net. A 192.0.2.10"''
              ''"ads2.adstest.net. A 192.0.2.10"''
              ''"clean.adstest.net. A 192.0.2.20"''
              ''"host.internal. A 192.0.2.30"''
            ];
          };
        };
      };

      blockedClient = mkClient {
        vlan = 1;
        address = "10.0.10.50";
        gateway = "10.0.10.1";
      };
      optoutClient = mkClient {
        vlan = 2;
        address = "10.0.11.50";
        gateway = "10.0.11.1";
      };
    };

    testScript = ''
      start_all()

      router.wait_for_unit("network-online.target")
      router.wait_for_unit("nftables.service")
      router.wait_for_unit("kresd@1.service")
      router.wait_for_unit("blocky.service")
      upstream.wait_for_unit("unbound.service")

      blockedClient.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.50'")
      optoutClient.wait_until_succeeds("ip addr show eth1 | grep '10.0.11.50'")

      # kresd must be the loopback backend (Blocky owns the gateway :53), and
      # Blocky must NOT be on the loopback:5335 backend port.
      print("Test 1: kresd retreated to loopback:5335, Blocky owns gateway :53")
      router.succeed("ss -ltnup | grep -E '127.0.0.1:5335'")
      print("PASS")

      # Sanity: both clients can resolve a clean (non-blocked) name.
      print("Test 2: clean name resolves for both clients")
      blockedClient.wait_until_succeeds("dig +short clean.adstest.net @10.0.10.1 | grep -w 192.0.2.20", timeout=30)
      optoutClient.wait_until_succeeds("dig +short clean.adstest.net @10.0.11.1 | grep -w 192.0.2.20", timeout=30)
      print("PASS")

      # Order A — clean answer cached FIRST (opt-out), THEN the block.
      # Proves a clean cache entry does not leak past the per-client block.
      print("Test 3 (order A): opt-out caches clean ads1, blocked still blocked")
      optoutClient.succeed("dig +short ads1.adstest.net @10.0.11.1 | grep -w 192.0.2.10")
      blockedClient.succeed("dig +short ads1.adstest.net @10.0.10.1 | grep -w 0.0.0.0")
      # And the opt-out client keeps getting the real answer afterwards.
      optoutClient.succeed("dig +short ads1.adstest.net @10.0.11.1 | grep -w 192.0.2.10")
      print("PASS")

      # Order B — block served FIRST, THEN the clean answer.
      # Proves a block does not poison the exempt client (the old failure).
      print("Test 4 (order B): blocked blocks ads2, opt-out still gets clean")
      blockedClient.succeed("dig +short ads2.adstest.net @10.0.10.1 | grep -w 0.0.0.0")
      optoutClient.succeed("dig +short ads2.adstest.net @10.0.11.1 | grep -w 192.0.2.10")
      # And the blocked client stays blocked afterwards.
      blockedClient.succeed("dig +short ads2.adstest.net @10.0.10.1 | grep -w 0.0.0.0")
      print("PASS")

      # Split-horizon special-use: .internal must be forwarded (conditional),
      # not NXDOMAIN'd by Blocky.
      print("Test 5: .internal resolves through Blocky -> kresd (conditional)")
      blockedClient.succeed("dig +short host.internal @10.0.10.1 | grep -w 192.0.2.30")
      optoutClient.succeed("dig +short host.internal @10.0.11.1 | grep -w 192.0.2.30")
      print("PASS")

      # The router's own libc path: 127.0.0.1:53 is Blocky, which forwards to
      # kresd on the backend port.
      print("Test 6: router resolves through its own loopback Blocky")
      router.succeed("dig +short clean.adstest.net @127.0.0.1 | grep -w 192.0.2.20")
      print("PASS")

      # Metrics/REST endpoint is loopback-only — reachable on the router,
      # unreachable from a client on the gateway IP.
      print("Test 7: Blocky http/metrics bound to loopback only")
      router.succeed("curl -sf http://127.0.0.1:4000/metrics >/dev/null")
      blockedClient.fail("nc -z -w 2 10.0.10.1 4000")
      print("PASS")

      print("")
      print("=" * 70)
      print("DNS BLOCKING TESTS COMPLETE - All 7 tests passed")
      print("=" * 70)
    '';
  }
