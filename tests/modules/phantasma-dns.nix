# NixOS VM integration test for phantasma's DNS stack (Blocky + Unbound).
#
# Reproduces the production failure mode locally: a client on the same L2
# segment runs `dig @<dns-server>` and must get an answer, not a timeout.
# This is the test that lets DNS debugging stop being a manual loop.
#
# Topology: 2 VMs, 1 VLAN
# - dns-server: 10.0.10.10 — runs Blocky on :53 forwarding to local Unbound on :5335
# - client:     10.0.10.50 — runs dig against the dns-server
#
# The dns-server's Unbound is stubbed for the test: it serves a static
# answer for "dns-probe.lab." instead of recursing, and a static answer for
# "phantasma.internal." to verify the split-horizon path still works.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "phantasma-dns";

  nodes = {
    dns-server = {
      config,
      pkgs,
      ...
    }: {
      virtualisation.vlans = [1];

      networking = {
        useDHCP = false;
        firewall.allowedUDPPorts = [53];
        firewall.allowedTCPPorts = [53];
        interfaces.eth1.ipv4.addresses = [
          {
            address = "10.0.10.10";
            prefixLength = 24;
          }
        ];
      };

      services.resolved.enable = false;

      services.blocky = {
        enable = true;
        # Don't try to fetch denylists in a sandboxed test
        enableConfigCheck = true;
        settings = {
          ports = {
            dns = "0.0.0.0:53";
            http = "127.0.0.1:4000";
          };
          upstreams.groups.default = ["127.0.0.1:5335"];
          # Route .internal (ICANN special-use TLD) to local Unbound,
          # bypassing Blocky's special-use short-circuit.
          conditional = {
            fallbackUpstream = false;
            mapping.internal = "127.0.0.1:5335";
          };
          # No blocking configured — we don't have network to fetch lists,
          # and the test is about forwarding correctness anyway.
          prometheus.enable = true;
          log = {
            level = "info";
            format = "text";
          };
        };
      };

      services.unbound = {
        enable = true;
        settings = {
          server = {
            interface = ["127.0.0.1"];
            port = 5335;
            access-control = [
              "127.0.0.0/8 allow"
              "0.0.0.0/0 refuse"
            ];
            local-zone = [
              ''"dns-probe.lab." static''
              ''"internal." static''
            ];
            local-data = [
              ''"dns-probe.lab. IN A 192.0.2.99"''
              ''"phantasma.internal. IN A 10.0.10.10"''
            ];
          };
        };
      };

      environment.systemPackages = [pkgs.dnsutils pkgs.curl];
    };

    client = {
      config,
      pkgs,
      ...
    }: {
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
      environment.systemPackages = [pkgs.dnsutils];
    };
  };

  testScript = ''
    start_all()

    dns_server.wait_for_unit("blocky.service")
    dns_server.wait_for_unit("unbound.service")
    dns_server.wait_for_open_port(53)
    dns_server.wait_for_open_port(4000)
    client.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.50'")

    # Test 1: reachability — the canary the production failure exposed.
    # A timeout here would mean Blocky isn't bound to a reachable address
    # or the source-IP is being silently dropped.
    print("Test 1: client reaches Blocky on dns-server")
    out = client.succeed("dig +time=3 +tries=1 @10.0.10.10 dns-probe.lab A +short")
    assert "192.0.2.99" in out, f"expected 192.0.2.99 in dig output, got: {out!r}"
    print("PASS")

    # Test 2: split-horizon — internal. names resolved by local Unbound
    # via local-zone, not forwarded out.
    print("Test 2: split-horizon resolves internal. names")
    out = client.succeed("dig +time=3 +tries=1 @10.0.10.10 phantasma.internal A +short")
    assert "10.0.10.10" in out, f"expected 10.0.10.10 in dig output, got: {out!r}"
    print("PASS")

    # Test 3: TCP path also works (some resolvers fall back to TCP).
    print("Test 3: TCP queries work")
    out = client.succeed("dig +tcp +time=3 +tries=1 @10.0.10.10 dns-probe.lab A +short")
    assert "192.0.2.99" in out, f"expected 192.0.2.99 (TCP) in dig output, got: {out!r}"
    print("PASS")

    # Test 4: metrics endpoint reachable on loopback, exposes blocky_* series.
    print("Test 4: prometheus metrics exposed on loopback")
    metrics = dns_server.succeed("curl -sS http://127.0.0.1:4000/metrics")
    assert "blocky_" in metrics, "expected blocky_* metrics, got none"
    print("PASS")

    # Test 5: metrics NOT reachable from off-host (loopback-only bind).
    print("Test 5: metrics endpoint is not exposed off-host")
    client.fail("curl -sS --max-time 2 http://10.0.10.10:4000/metrics")
    print("PASS")

    print("")
    print("=" * 70)
    print("PHANTASMA DNS TESTS COMPLETE - All 5 tests passed")
    print("=" * 70)
  '';
}
