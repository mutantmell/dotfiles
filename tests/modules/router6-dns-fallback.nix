# Strict-failover integration test for router6 kresd.
#
# Verifies the three guarantees the broken phase-1 design could not provide:
#
#   A. Healthy primary → 100% of user queries answer with primary's marker
#      (no NS-reputation "drift" to fallback while primary is up).
#   B. After primary stops, the breaker trips within a bounded query budget,
#      and ALL subsequent queries route to fallback.
#   C. After primary is restored, a single successful probe (within
#      PRIMARY_RETRY + buffer) resets the breaker and queries flow to primary
#      again.
#
# Topology: single VLAN, three machines.
#   router    10.0.10.1   router6 + kresd, strict-failover dispatch
#   primary   10.0.10.10  fake "phantasma" — unbound, test.example A=192.0.2.10
#                         and a synthetic root SOA so the kresd probe gets
#                         NOERROR while reachable.
#   fallback  10.0.10.20  fake ISP DNS — unbound, test.example A=192.0.2.20
#
# The router sets dns.fallbackFromLease = "eth1". With no DHCP lease present
# the renderer service falls through to its write_static branch and emits the
# dns.fallbackUpstream list into /run/knot-resolver/isp-dns.lua before kresd
# starts, which is the shape kresd's dofile() expects.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  # Labels the testScript queries through kresd. unbound's `static`
  # local-zone does not honor wildcards, so each label has to be enumerated
  # in local-data explicitly. b-probe-* and c-probe-* labels are used in the
  # polling loops; each iteration uses a distinct label so kresd's cache
  # can't paper over a primary→fallback transition (or vice versa) by
  # serving a previously-cached marker.
  testLabels =
    ["diag"]
    ++ (map (i: "a${toString i}") (lib.range 0 19))
    ++ (map (i: "b-probe-${toString i}") (lib.range 0 60))
    ++ (map (i: "b${toString i}") (lib.range 0 9))
    ++ (map (i: "c-probe-${toString i}") (lib.range 0 60))
    ++ (map (i: "c${toString i}") (lib.range 0 4));
  # Authoritative test server. Distinct A record per upstream so a query
  # answer identifies which target kresd selected. Also serves a synthetic
  # root SOA so the kresd health probe (`. SOA`) sees NOERROR — a real
  # recursive primary would; an authoritative-only server would REFUSE,
  # which would trip the breaker against a healthy primary in this test.
  mkFakeResolver = {
    addr,
    answer,
  }: {
    imports = [../lib/test-minimal-base.nix];
    virtualisation.vlans = [1];

    networking = {
      useDHCP = false;
      firewall.allowedUDPPorts = [53];
      firewall.allowedTCPPorts = [53];
      interfaces.eth1.ipv4.addresses = [
        {
          address = addr;
          prefixLength = 24;
        }
      ];
    };

    services.resolved.enable = false;

    services.unbound = {
      enable = true;
      settings = {
        server = {
          interface = ["0.0.0.0"];
          port = 53;
          access-control = ["0.0.0.0/0 allow"];
          do-not-query-localhost = "no";
          local-zone = [
            ''"test.example." static''
            ''"." static''
          ];
          local-data =
            [
              ''"test.example. IN A ${answer}"''
              ''"primary.test.example. IN A ${answer}"''
              ''"fallback.test.example. IN A ${answer}"''
              ''". 3600 IN SOA root. nobody. 1 3600 600 86400 3600"''
              ''". 3600 IN NS root."''
            ]
            ++ (map (label: ''"${label}.test.example. IN A ${answer}"'') testLabels);
        };
      };
    };

    environment.systemPackages = [pkgs.dnsutils];
  };
  testRunner = import ../lib/container-test-runner.nix {inherit pkgs lib;};
in
  testRunner {
    name = "router6-dns-fallback";

    containers = {
      primary = _:
        mkFakeResolver {
          addr = "10.0.10.10";
          answer = "192.0.2.10";
        };

      fallback = _:
        mkFakeResolver {
          addr = "10.0.10.20";
          answer = "192.0.2.20";
        };

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
            upstream = ["10.0.10.10"];
            fallbackFromLease = "eth1";
            fallbackUpstream = ["10.0.10.20"];
            # Fake resolvers serve unsigned data — DNSSEC validation would
            # SERVFAIL every test query.
            enableDNSSEC = false;
          };

          topology = {
            eth1 = {
              hardwareName = "eth1";
              network = {
                type = "static";
                addresses = ["10.0.10.1/24"];
                zone = "trusted";
                subnetId = 10;
              };
            };
          };
        };

        services.kea.dhcp4.enable = lib.mkForce false;
        services.kea.dhcp6.enable = lib.mkForce false;

        environment.systemPackages = [pkgs.dnsutils];
      };
    };

    testScript = ''
      import time

      start_all()

      primary.wait_for_unit("unbound.service")
      fallback.wait_for_unit("unbound.service")
      primary.wait_for_open_port(53)
      fallback.wait_for_open_port(53)

      router.wait_for_unit("network.target")
      router.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.1'")
      router.wait_for_unit("kresd-isp-fallback-render.service")
      router.succeed("test -s /run/knot-resolver/isp-dns.lua")
      router.succeed("grep -F '10.0.10.20' /run/knot-resolver/isp-dns.lua")
      router.wait_for_unit("kresd@1.service")
      router.wait_until_succeeds("nc -z -w 2 127.0.0.1 53")

      # Preflight: both upstreams answer directly.
      router.succeed("dig +time=3 +tries=1 @10.0.10.10 primary.test.example A +short | grep -F 192.0.2.10")
      router.succeed("dig +time=3 +tries=1 @10.0.10.20 fallback.test.example A +short | grep -F 192.0.2.20")
      # And the synthetic root SOA the kresd probe relies on.
      router.succeed("dig +time=3 +tries=1 @10.0.10.10 . SOA +short | grep -F root.")

      def dig_short(label):
          # +tries=1 tightens the loop. +time=4 leaves room for one normal
          # round-trip. dig exits 9 on timeout (e.g. while primary is
          # blackholed and the breaker hasn't tripped yet); the polling
          # loops below treat empty output as "not yet" rather than fatal.
          _, out = router.execute(
              f"dig +time=4 +tries=1 @127.0.0.1 {label}.test.example A +short"
          )
          return out.strip()

      # ====================================================================
      # A. Strict primary preference — every one of 20 queries goes to
      #    primary. This is the assertion the broken concatenated-FORWARD
      #    design cannot satisfy.
      # ====================================================================
      print("A: strict primary preference under healthy upstreams")
      results = []
      for i in range(20):
          # Distinct labels keep kresd from cache-coalescing the loop.
          out = dig_short(f"a{i}")
          results.append(out)

      primary_count = sum(1 for r in results if "192.0.2.10" in r)
      fallback_count = sum(1 for r in results if "192.0.2.20" in r)
      assert primary_count == 20, (
          f"strict-primary failed: {primary_count}/20 from primary, "
          f"{fallback_count}/20 from fallback (results: {results})"
      )
      assert fallback_count == 0, (
          f"unexpected fallback responses while primary up: {results}"
      )
      print(f"PASS ({primary_count}/20 from primary, 0 from fallback)")

      # ====================================================================
      # B. Failover when primary goes down.
      #    iptables DROP simulates a stalled primary (no RST, no ICMP
      #    unreachable), which is the failure mode strict failover is meant
      #    to handle. A clean `systemctl stop unbound` produces ICMP
      #    port-unreachable and kresd's selection logic reacts differently.
      # ====================================================================
      print("B: drop primary, expect breaker to trip and route to fallback")
      primary.succeed("iptables -I INPUT -p udp --dport 53 -j DROP")
      primary.succeed("iptables -I INPUT -p tcp --dport 53 -j DROP")

      # Breaker is fed by probes (every 5s) — give it room to count three
      # consecutive probe failures. PRIMARY_THRESHOLD * PROBE_INTERVAL ≈ 15s
      # under happy timing; pad for VM clock + probe-timeout slack.
      tripped = False
      attempt = 0
      deadline = time.monotonic() + 60
      while time.monotonic() < deadline:
          out = dig_short(f"b-probe-{attempt}")
          attempt += 1
          if "192.0.2.20" in out:
              tripped = True
              break
          time.sleep(1)

      assert tripped, "breaker never tripped after primary blackholed"

      # Once tripped, every subsequent query must hit fallback.
      sticky = []
      for i in range(10):
          sticky.append(dig_short(f"b{i}"))
      assert all("192.0.2.20" in r for r in sticky), (
          f"breaker not sticky after trip: {sticky}"
      )
      print("PASS (breaker tripped and stuck on fallback)")

      # ====================================================================
      # C. Recovery after PRIMARY_RETRY cooldown.
      # ====================================================================
      print("C: restore primary, expect breaker to reset after PRIMARY_RETRY")
      primary.succeed("iptables -D INPUT -p udp --dport 53 -j DROP")
      primary.succeed("iptables -D INPUT -p tcp --dport 53 -j DROP")
      primary.wait_until_succeeds("dig +time=3 +tries=1 @127.0.0.1 . SOA +short")

      recovered = False
      attempt = 0
      # PRIMARY_RETRY is 30s; allow PROBE_INTERVAL + slack on top.
      deadline = time.monotonic() + 60
      while time.monotonic() < deadline:
          out = dig_short(f"c-probe-{attempt}")
          attempt += 1
          if "192.0.2.10" in out:
              recovered = True
              break
          time.sleep(2)

      assert recovered, "breaker did not reset after primary restored"

      # Confirm sticky again on the recovered side.
      sticky = []
      for i in range(5):
          sticky.append(dig_short(f"c{i}"))
      assert all("192.0.2.10" in r for r in sticky), (
          f"primary not sticky after recovery: {sticky}"
      )
      print("PASS (primary re-elected and sticky)")
    '';
  }
