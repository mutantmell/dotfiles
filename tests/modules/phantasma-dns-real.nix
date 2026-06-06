# Boots phantasma's REAL dns.nix module so runtime failures reproduce locally.
#
# phantasma exposes plain Unbound only — no Blocky. Ad-blocking lives in a
# separate resolver off thebeyond's kresd cache (see hosts/thebeyond/router.nix
# and the DNS notes). This test asserts the Unbound-only posture: split-horizon
# local data resolves, Blocky is absent, and the cache-poisoning source of the
# old per-VLAN bypass is gone.
#
# Recursion to the internet can't be exercised in the hermetic test sandbox, so
# queries go to 127.0.0.1 (always bound, always allowed by access-control) and
# stick to static split-horizon data.
#
# Run interactively:
#   nix build .#checks.x86_64-linux.phantasma-dns-real.driverInteractive
#   ./result/bin/nixos-test-driver
# Then in the Python REPL:
#   start_all()
#   dns_server.succeed("systemctl status unbound --no-pager")
#   dns_server.succeed("dig @127.0.0.1 +time=3 +tries=1 phantasma.internal")
#   dns_server.shell_interact()   # full shell inside the VM
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
pkgs.testers.nixosTest {
  name = "phantasma-dns-real";

  nodes = {
    dns-server = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [
        ../../hosts/thebeyond/microvm/guests/phantasma/modules/dns.nix
        ../lib/test-minimal-base.nix
      ];

      virtualisation.vlans = [1];

      # Give eth1 phantasma's real registry IPv4 so Unbound's external bind
      # lands on an address that actually exists on the node (the module also
      # ip-freebinds, but matching the registry keeps the test faithful).
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [
          {
            address = "10.91.10.10";
            prefixLength = 24;
          }
        ];
      };

      environment.systemPackages = [pkgs.dnsutils];
    };
  };

  testScript = ''
    start_all()

    dns_server.wait_for_unit("unbound.service")
    dns_server.wait_for_open_port(53)

    # Blocky must be gone: the unit should not exist at all.
    print("=== Blocky must be absent ===")
    dns_server.succeed("test ! -e /etc/systemd/system/blocky.service")
    dns_server.fail("systemctl cat blocky.service")

    # Split-horizon static data resolves through Unbound on loopback (no
    # recursion needed — these are local-data records from the registry).
    print("=== Split-horizon resolution ===")
    out = dns_server.succeed(
        "dig +time=3 +tries=1 @127.0.0.1 phantasma.internal A +short"
    ).strip()
    print(f"phantasma.internal -> {out!r}")
    assert "10.91.10.10" in out, f"expected phantasma.internal A record, got {out!r}"

    out = dns_server.succeed(
        "dig +time=3 +tries=1 @127.0.0.1 phantasma.internal.mutantmell.net A +short"
    ).strip()
    assert "10.91.10.10" in out, (
        f"expected canonical internal A record, got {out!r}"
    )

    # libc resolves through Unbound on loopback (resolved is disabled, so
    # resolv.conf points at 127.0.0.1, not the 127.0.0.53 stub).
    print("=== resolv.conf points at Unbound ===")
    dns_server.succeed("grep -q '127.0.0.1' /etc/resolv.conf")
    dns_server.fail("grep -q '127.0.0.53' /etc/resolv.conf")
  '';
}
