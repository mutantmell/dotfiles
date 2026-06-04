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
    ++ (map (i: "c${toString i}") (lib.range 0 4))
    # Guest-VLAN (source-routed) labels: healthy (g-a), during-outage (g-b),
    # post-recovery (g-c). Distinct labels keep kresd's cache from masking a
    # no-block ↔ fallback transition for the guest path.
    ++ (map (i: "g-a${toString i}") (lib.range 0 4))
    ++ (map (i: "g-b${toString i}") (lib.range 0 9))
    ++ (map (i: "g-c${toString i}") (lib.range 0 4));

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
in
  pkgs.testers.nixosTest {
    name = "router6-dns-fallback";

    nodes = {
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

      # No-block upstream for the guest VLAN source route (stands in for
      # phantasma's recursive Unbound on :5335). Distinct marker so guest
      # answers identify the no-block path vs. primary/fallback.
      noblock = _:
        mkFakeResolver {
          addr = "10.0.10.30";
          answer = "192.0.2.30";
        };

      # Guest-VLAN client. Its source IP (10.0.10.50) is matched by the
      # router's sourceRoutes CIDR, so its queries are dispatched to the
      # no-block upstream while the primary is healthy, and must follow the
      # breaker to the ISP fallback when the primary goes down.
      guest = {pkgs, ...}: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [1];
        networking = {
          useDHCP = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "10.0.10.50";
              prefixLength = 24;
            }
          ];
        };
        services.resolved.enable = false;
        environment.systemPackages = [pkgs.dnsutils];
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
            # Guest VLAN (here just the guest client's /32) bypasses the
            # primary path, routing straight to the no-block upstream — but
            # must still fail over to the ISP fallback when the breaker trips.
            sourceRoutes = [
              {
                cidr = "10.0.10.50/32";
                upstream = ["10.0.10.30"];
              }
              # Load-time parse guard: a real kresd must accept an IPv6
              # `addr@port` upstream at config load. The guest client is IPv4,
              # so this v6 CIDR never matches a query — it only forces kresd to
              # parse the v6 form. Catches the bracketed `[addr]@port` mistake
              # that addr2sock (policy.lua) rejects, which a string-only eval
              # test cannot see. NO brackets.
              {
                cidr = "fd00:0:0:1e::/64";
                upstream = ["fd00:0:0:a::30@5335"];
              }
            ];
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
      noblock.wait_for_unit("unbound.service")
      primary.wait_for_open_port(53)
      fallback.wait_for_open_port(53)
      noblock.wait_for_open_port(53)

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

      guest.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.50'")
      # Preflight: the guest's no-block upstream answers directly.
      router.succeed("dig +time=3 +tries=1 @10.0.10.30 g-a0.test.example A +short | grep -F 192.0.2.30")

      def dig_short(label):
          # +tries=1 tightens the loop. +time=4 leaves room for one normal
          # round-trip. dig exits 9 on timeout (e.g. while primary is
          # blackholed and the breaker hasn't tripped yet); the polling
          # loops below treat empty output as "not yet" rather than fatal.
          _, out = router.execute(
              f"dig +time=4 +tries=1 @127.0.0.1 {label}.test.example A +short"
          )
          return out.strip()

      def guest_dig(label):
          # Guest queries kresd over the VLAN (source IP 10.0.10.50) so the
          # router's source route matches; querying @127.0.0.1 from the router
          # would not.
          _, out = guest.execute(
              f"dig +time=4 +tries=1 @10.0.10.1 {label}.test.example A +short"
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
      # A2. Guest source route — while primary is healthy, the guest VLAN
      #     bypasses the primary path entirely and lands on the no-block
      #     upstream (192.0.2.30), never primary (.10) or fallback (.20).
      # ====================================================================
      print("A2: guest source route to no-block upstream while healthy")
      guest_results = [guest_dig(f"g-a{i}") for i in range(5)]
      assert all("192.0.2.30" in r for r in guest_results), (
          f"guest did not route to no-block upstream while healthy: {guest_results}"
      )
      assert not any(("192.0.2.10" in r or "192.0.2.20" in r) for r in guest_results), (
          f"guest leaked to primary/fallback while healthy: {guest_results}"
      )
      print("PASS (guest on no-block upstream)")

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
      # B2. The guest source route must follow the breaker. This is the
      #     guarantee the user asked about: when the shared backend
      #     (phantasma/Unbound) is down, the guest VLAN must NOT keep aiming
      #     at the dead no-block upstream — it fails over to the ISP fallback
      #     (192.0.2.20) like everyone else, never SERVFAILing.
      # ====================================================================
      print("B2: guest source route follows the breaker to fallback")
      guest_sticky = [guest_dig(f"g-b{i}") for i in range(10)]
      assert all("192.0.2.20" in r for r in guest_sticky), (
          f"guest did not fail over to fallback after breaker tripped: {guest_sticky}"
      )
      assert not any("192.0.2.30" in r for r in guest_sticky), (
          f"guest still aiming at the dead no-block upstream during outage: {guest_sticky}"
      )
      print("PASS (guest failed over to fallback)")

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

      # ====================================================================
      # C2. Once the breaker resets, the guest source route returns to the
      #     no-block upstream (192.0.2.30) rather than staying on fallback.
      # ====================================================================
      print("C2: guest source route returns to no-block after recovery")
      guest_recovered = False
      attempt = 0
      deadline = time.monotonic() + 30
      while time.monotonic() < deadline:
          out = guest_dig(f"g-c{attempt % 5}")
          attempt += 1
          if "192.0.2.30" in out:
              guest_recovered = True
              break
          time.sleep(2)
      assert guest_recovered, "guest source route did not return to no-block upstream after recovery"
      print("PASS (guest back on no-block upstream)")
    '';
  }
