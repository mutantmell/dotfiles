# Regression test for the network-zone phantasma egress rule.
#
# Production phantasma lives in the `network` zone (alongside APs/switches),
# but unlike the rest of that zone it MUST be able to reach root DNS servers
# and NTP servers. The forward rule is restricted by saddr so that general
# network-zone gear does not inherit internet egress.
#
# This test asserts that the router6 module faithfully renders:
#   forwardRules.external = ds { saddr = phantasma; udp.dport = 53; ... };
# into a saddr-scoped nftables accept (both v4 and v6), and that there is
# no blanket network -> external accept that would expose the rest of the
# zone to the internet.
#
# Caught a real outage on 2026-05-13 where the `network` zone had
# `accessTo = []` and no `forwardRules.external`, so phantasma's Unbound
# couldn't recurse and Blocky returned ServFail for every query.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  # Mimic a host record (ipv4 + ipv6) for use with mkDualStackRules.
  phantasma = {
    ipv4 = "10.0.50.10";
    ipv6 = "fdc6:55f2:0a5e:32::10";
  };

  net = pkgs.mmell.lib.data.network;
  ds = net.mkDualStackRules;
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-network-zone-egress";

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

        # eth1 (vlan1) = WAN/external (203.0.113.0/24)
        # eth2 (vlan2) = network      (10.0.50.0/24, fdc6:55f2:0a5e:32::/64)
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
            network = {
              icmpEcho = "enable";
              accessTo = [];
              forwardRules.external =
                (ds {
                  saddr = phantasma;
                  udp.dport = 53;
                  verdict = "accept";
                  comment = "phantasma -> internet (recursive DNS)";
                })
                ++ (ds {
                  saddr = phantasma;
                  tcp.dport = 53;
                  verdict = "accept";
                  comment = "phantasma -> internet (recursive DNS TCP)";
                })
                ++ (ds {
                  saddr = phantasma;
                  udp.dport = 123;
                  verdict = "accept";
                  comment = "phantasma -> internet (NTP)";
                });
              inputRules = [];
            };
          };

          dns = {
            upstream = ["1.1.1.1"];
            localDomain = "test.local";
          };

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
                addresses = [
                  "10.0.50.1/24"
                  "fdc6:55f2:0a5e:32::1/64"
                ];
                zone = "network";
              };
            };
          };
        };

        # Test exercises nftables forward rules only — no DNS or DHCP probes.
        services.kresd.enable = lib.mkForce false;
        services.kea.dhcp4.enable = lib.mkForce false;
        services.kea.dhcp6.enable = lib.mkForce false;
        # kea normally wants network-online.target; without it nothing pulls
        # up that target. Anchor it to multi-user.target so it still activates.
        systemd.targets.network-online.wantedBy = ["multi-user.target"];
      };
    };

    testScript = ''
      start_all()

      router.wait_for_unit("network-online.target")
      router.wait_for_unit("nftables.service")

      # ======================================================================
      # RULE PRESENCE: saddr-restricted forwardRules render correctly
      # ======================================================================
      # Actual rule format produced by router6:
      #   iifname "eth2" ip  saddr 10.0.50.10            oifname "eth1" udp dport 53 accept
      #   iifname "eth2" ip6 saddr fdc6:55f2:a5e:32::10  oifname "eth1" udp dport 53 accept
      # Note: nft strips one leading zero from each address segment, so the
      # config's "fdc6:55f2:0a5e:32::10" renders as "fdc6:55f2:a5e:32::10".

      print("Test 1: v4 saddr-restricted UDP/53 forward rule present")
      router.succeed(
        "nft list chain inet filter forward | "
        "grep -E 'iifname \"eth2\" ip saddr 10\\.0\\.50\\.10 oifname \"eth1\" udp dport 53 accept'"
      )
      print("PASS")

      print("Test 2: v4 saddr-restricted TCP/53 forward rule present")
      router.succeed(
        "nft list chain inet filter forward | "
        "grep -E 'iifname \"eth2\" ip saddr 10\\.0\\.50\\.10 oifname \"eth1\" tcp dport 53 accept'"
      )
      print("PASS")

      print("Test 3: v4 saddr-restricted UDP/123 forward rule present")
      router.succeed(
        "nft list chain inet filter forward | "
        "grep -E 'iifname \"eth2\" ip saddr 10\\.0\\.50\\.10 oifname \"eth1\" udp dport 123 accept'"
      )
      print("PASS")

      print("Test 4: v6 saddr-restricted UDP/53 forward rule present")
      router.succeed(
        "nft list chain inet filter forward | "
        "grep -E 'iifname \"eth2\" ip6 saddr fdc6:55f2:a5e:32::10 oifname \"eth1\" udp dport 53 accept'"
      )
      print("PASS")

      print("Test 5: v6 saddr-restricted TCP/53 forward rule present")
      router.succeed(
        "nft list chain inet filter forward | "
        "grep -E 'iifname \"eth2\" ip6 saddr fdc6:55f2:a5e:32::10 oifname \"eth1\" tcp dport 53 accept'"
      )
      print("PASS")

      print("Test 6: v6 saddr-restricted UDP/123 forward rule present")
      router.succeed(
        "nft list chain inet filter forward | "
        "grep -E 'iifname \"eth2\" ip6 saddr fdc6:55f2:a5e:32::10 oifname \"eth1\" udp dport 123 accept'"
      )
      print("PASS")

      # ======================================================================
      # GENERAL NETWORK-ZONE EGRESS: must NOT exist
      # ======================================================================
      # A blanket eth2 -> eth1 accept (no saddr predicate) would mean every
      # AP/switch in the network zone got internet egress too — the opposite
      # bug. Ensure no such rule exists.
      print("Test 7: no blanket network -> external accept (saddr-less)")
      router.fail(
        "nft list chain inet filter forward | "
        "grep -E 'iifname \"eth2\" oifname \"eth1\"[[:space:]]+accept'"
      )
      print("PASS")

      # Negative: only the three permitted protos/dports show up. There must
      # be NO accept rule for, say, TCP/80 from phantasma — saddr alone isn't
      # a free pass.
      print("Test 8: phantasma saddr does not get TCP/80 accept")
      router.fail(
        "nft list chain inet filter forward | "
        "grep -E 'iifname \"eth2\".*ip saddr 10\\.0\\.50\\.10.*oifname \"eth1\".*tcp dport 80 accept'"
      )
      print("PASS")

      print("")
      print("=" * 70)
      print("NETWORK-ZONE EGRESS TESTS COMPLETE")
      print("=" * 70)
    '';
  }
