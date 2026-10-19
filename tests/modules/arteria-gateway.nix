{
  pkgs,
  lib,
}: let
  base = {
    imports = [../lib/test-minimal-base.nix];
    virtualisation.vlans = [1];
    networking.useDHCP = false;
    networking.firewall.enable = false;
    environment.systemPackages = with pkgs; [iproute2 netcat-openbsd dhcpcd dig tcpdump];
  };
in
  pkgs.testers.nixosTest {
    name = "arteria-gateway";
    nodes = {
      router = {lib, ...}: {
        imports = [base ../../modules/router6 ../../hosts/arteria/router.nix];
        # The VM has a separate test-driver NIC. Rename only its trunk NIC.
        systemd.network.links."10-trunk" = {
          matchConfig.OriginalName = "eth1";
          linkConfig.Name = "uplink";
        };
        networking.firewall.enable = lib.mkForce false;
        services.openssh.enable = true;
        router6.dns.localRecords = {
          "override.pages.internal".addresses = ["192.0.2.42"];
          "nested.pages.internal" = {
            addresses = ["192.0.2.43"];
            includeSubdomains = true;
          };
          "v4only.internal".addresses = ["192.0.2.44"];
          "multi.internal" = {
            addresses = ["192.0.2.45" "192.0.2.46"];
            ttl = 17;
          };
        };
      };
      cluster = base;
      app = {
        imports = [base];
        systemd.services.listener = {
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP6-LISTEN:443,ipv6only=0,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/cat";
        };
      };
      upstream = {
        imports = [base];
        services.unbound = {
          enable = true;
          resolveLocalQueries = false;
          enableRootTrustAnchor = false;
          settings.server = {
            interface = ["0.0.0.0"];
            access-control = ["0.0.0.0/0 allow"];
            module-config = "iterator";
            # A conflicting upstream answer exposes accidental forwarding of
            # unknown internal names; external test names must still forward.
            local-zone = [
              "\"forwarded.openwrt.org.\" static"
              "\"internal.\" redirect"
              "\"internal.mutantmell.net.\" redirect"
            ];
            local-data = [
              "\"forwarded.openwrt.org. A 198.51.100.42\""
              "\"forwarded.openwrt.org. AAAA 2001:db8::42\""
              "\"internal. A 192.0.2.99\""
              "\"internal.mutantmell.net. A 192.0.2.99\""
            ];
          };
        };
      };
    };
    testScript = ''
      start_all()
      router.wait_for_unit("systemd-networkd.service")
      router.wait_for_unit("kea-dhcp4-server.service")
      router.wait_for_unit("kea-dhcp6-server.service")
      router.wait_for_unit("kresd@1.service")
      upstream.wait_for_unit("unbound.service")
      router.wait_until_succeeds("ip -4 addr show uplink.255 | grep 10.255.255.2")
      router.succeed("ip -4 route show default | grep 'via 10.255.255.1 dev uplink.255'")
      router.succeed("ip -6 route show default | grep 'via fdc6:55f2:a5e:ffff::1 dev uplink.255'")
      assert "masquerade" not in router.succeed("nft list ruleset")
      assert "snat" not in router.succeed("nft list ruleset")
      for vid in [11, 12, 20, 21, 50, 51, 255]:
          router.succeed(f"ip -d link show uplink.{vid} | grep 'id {vid}'")

      def vlan(machine, vid, addresses):
          machine.succeed(f"ip link set eth1 up; ip link add link eth1 name eth1.{vid} type vlan id {vid}; ip link set eth1.{vid} up")
          for address in addresses:
              machine.succeed(f"ip addr add {address} dev eth1.{vid}")

      vlan(upstream, 255, ["10.255.255.1/30", "fdc6:55f2:a5e:ffff::1/64"])
      upstream.succeed("ip addr add 198.51.100.1/32 dev lo; ip addr add 2001:db8::1/128 dev lo")
      upstream.succeed("ip route add 10.97.0.0/16 via 10.255.255.2; ip -6 route add fdc6:55f2:a5e:1000::/52 via fdc6:55f2:a5e:ffff::2")
      vlan(app, 50, ["10.97.50.53/24", "10.97.50.31/24", "10.97.50.52/24", "fdc6:55f2:a5e:1032::35/64", "fdc6:55f2:a5e:1032::1f/64", "fdc6:55f2:a5e:1032::34/64"])
      app.succeed("ip route replace default via 10.97.50.1 dev eth1.50; ip -6 route replace default via fdc6:55f2:a5e:1032::1 dev eth1.50")
      app.wait_for_unit("listener.service")

      vlan(cluster, 51, [])
      cluster.succeed("ip link set eth1.51 down; ip link set eth1.51 address 02:51:51:00:00:0a; ip link set eth1.51 up")
      cluster.succeed("dhcpcd -4 --noipv4ll --timeout 30 eth1.51")
      cluster.wait_until_succeeds("ip -4 addr show eth1.51 | grep 10.97.51.10/24")
      # Route probes through the gateway rather than the VM's driver/NAT NIC.
      cluster.succeed("ip route replace default via 10.97.51.1 dev eth1.51")
      cluster.wait_until_succeeds("ip -6 route show default | grep 'dev eth1.51'", timeout=60)
      cluster.succeed("ip -6 addr add fdc6:55f2:a5e:1033::a/64 dev eth1.51")
      cluster.succeed("nc -z -w 3 10.97.51.1 53")
      cluster.succeed("nc -6 -z -w 3 fdc6:55f2:a5e:1033::1 53")
      # Query through the real IPv4/IPv6 gateway listeners, not the backend.
      import ipaddress
      records = {
          "arteria.internal": ("10.97.11.1", "fdc6:55f2:a5e:100b::1"),
          "arteria.internal.mutantmell.net": ("10.97.11.1", "fdc6:55f2:a5e:100b::1"),
          "forgejo.internal": ("10.97.50.53", "fdc6:55f2:a5e:1032::35"),
          "attic.zeiss.internal.mutantmell.net": ("10.97.50.31", "fdc6:55f2:a5e:1032::1f"),
          "pages.internal": ("10.97.50.53", "fdc6:55f2:a5e:1032::35"),
          "new-user.pages.internal": ("10.97.50.53", "fdc6:55f2:a5e:1032::35"),
      }
      def check_local_records():
          for server in ["10.97.51.1", "fdc6:55f2:a5e:1033::1"]:
              for name, addresses in records.items():
                  for rrtype, expected in zip(["A", "AAAA"], addresses):
                      answer = cluster.succeed(f"dig +time=2 +tries=1 @{server} {name} {rrtype} +short").strip()
                      assert ipaddress.ip_address(answer) == ipaddress.ip_address(expected), (server, name, rrtype, answer)
              for name in ["missing.internal", "missing.internal.mutantmell.net", "bt8gw.internal"]:
                  cluster.succeed(f"dig +time=2 +tries=1 @{server} {name} A +comments | grep 'status: NXDOMAIN'")

          # Exact records override redirect parents; longest redirect wins.
          for name, expected in [
              ("override.pages.internal", "192.0.2.42"),
              ("child.nested.pages.internal", "192.0.2.43"),
          ]:
              answer = cluster.succeed(f"dig +time=2 +tries=1 @10.97.51.1 {name} A +short").strip()
              assert answer == expected, (name, answer)
          # Known name/missing type is NODATA and must never go upstream.
          answer = cluster.succeed("dig +time=2 +tries=1 @10.97.51.1 v4only.internal AAAA +comments")
          assert "status: NOERROR" in answer and "ANSWER: 0" in answer, answer
          answer = cluster.succeed("dig +time=2 +tries=1 @10.97.51.1 multi.internal A +short").strip()
          assert set(answer.splitlines()) == {"192.0.2.45", "192.0.2.46"}, answer
          cluster.succeed("dig +time=2 +tries=1 @10.97.51.1 multi.internal A +noall +answer | grep -E '17[[:space:]]+IN[[:space:]]+A'")
          cluster.succeed("dig +tcp +time=2 +tries=1 @10.97.51.1 arteria.internal A +short | grep 10.97.11.1")

      check_local_records()
      for rrtype, expected in [("A", "198.51.100.42"), ("AAAA", "2001:db8::42")]:
          answer = cluster.succeed(f"dig +time=2 +tries=1 @10.97.51.1 forwarded.openwrt.org {rrtype} +short").strip()
          assert ipaddress.ip_address(answer) == ipaddress.ip_address(expected), (rrtype, answer)
      # No second DNS daemon/backend is needed on the gateway.
      router.fail("systemctl cat unbound.service")
      router.fail("ss -lntup | grep :5353")
      # Restart kresd and clear its on-disk cache. Internal answers, including
      # fresh NXDOMAINs and Pages children, must work with no upstream resolver.
      upstream.succeed("systemctl stop unbound")
      router.succeed("systemctl stop kresd@1")
      router.succeed("rm -f /var/cache/knot-resolver/*.mdb")
      router.succeed("systemctl start kresd@1")
      router.wait_for_unit("kresd@1.service")
      check_local_records()
      # DHCP-advertised DNS and RA DNS point at the actual gateway interfaces.
      router.succeed("grep -F 'fdc6:55f2:0a5e:1033::1' /etc/systemd/network/*uplink.51.network")
      cluster.succeed("ping -c 1 -W 3 198.51.100.1")
      cluster.succeed("ping -6 -c 1 -W 3 2001:db8::1")
      # Capture actual forwarded sources on both families, rather than merely
      # inferring no NAT from the configuration.
      upstream.succeed("tcpdump -ni eth1.255 -c 1 'icmp and src host 10.97.51.10' > /tmp/source4 2>&1 &")
      upstream.wait_until_succeeds("grep 'listening on' /tmp/source4")
      cluster.succeed("ping -c 1 -W 3 198.51.100.1")
      upstream.wait_until_succeeds("grep '10.97.51.10 > 198.51.100.1' /tmp/source4")
      upstream.succeed("tcpdump -ni eth1.255 -c 1 'icmp6 and src host fdc6:55f2:a5e:1033::a' > /tmp/source6 2>&1 &")
      upstream.wait_until_succeeds("grep 'listening on' /tmp/source6")
      cluster.succeed("ping -6 -I fdc6:55f2:a5e:1033::a -c 1 -W 3 2001:db8::1")
      upstream.wait_until_succeeds("grep 'fdc6:55f2:a5e:1033::a > 2001:db8::1' /tmp/source6")
      for address in ["10.97.50.53", "10.97.50.31", "fdc6:55f2:a5e:1032::35", "fdc6:55f2:a5e:1032::1f"]:
          cluster.succeed(f"nc -z -w 3 {address} 443")
      for address in ["10.97.50.52", "fdc6:55f2:a5e:1032::34"]:
          cluster.fail(f"nc -z -w 2 {address} 443")
      for address in ["10.255.255.1", "fdc6:55f2:a5e:ffff::1"]:
          cluster.fail(f"ping -c 1 -W 2 {address}")
      cluster.fail("nc -z -w 2 10.97.51.1 22")
      # Administrative VLAN can reach the gateway over the same physical trunk.
      vlan(app, 11, ["10.97.11.90/24"])
      app.succeed("ping -c 1 -W 3 10.97.11.1")
      router.wait_for_unit("sshd.service")
      app.succeed("nc -z -w 3 10.97.11.1 22")
      cluster.fail("ping -c 1 -W 2 10.97.11.90")
    '';
  }
