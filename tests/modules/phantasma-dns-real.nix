# Interactive nixosTest that boots phantasma's REAL dns.nix module.
#
# Unlike phantasma-dns.nix which uses an inline Blocky config, this test
# imports the actual production module so we can reproduce runtime
# failures locally.
#
# Run interactively:
#   nix build .#checks.x86_64-linux.phantasma-dns-real.driverInteractive
#   ./result/bin/nixos-test-driver
# Then in the Python REPL:
#   start_all()
#   dns_server.succeed("systemctl status blocky --no-pager")
#   dns_server.succeed("dig @127.0.0.1 +time=3 +tries=1 google.com")
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
      ];

      virtualisation.vlans = [1];

      networking = {
        useDHCP = false;
        # Override the production firewall openings to also include SSH for
        # the test driver. Leave 53 alone (dns.nix already opens it).
        interfaces.eth1.ipv4.addresses = [
          {
            address = "10.0.10.10";
            prefixLength = 24;
          }
        ];
      };

      # The production denylist is now a local store path (pinned via
      # the stevenblack-hosts flake input), so no test override needed.
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
    client.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.50'")

    # Baseline: client can reach Blocky and split-horizon resolves.
    print("=== Baseline checks ===")
    out = client.succeed("dig +time=3 +tries=1 @10.0.10.10 phantasma.internal A +short")
    print(f"phantasma.internal -> {out!r}")

    print("=== Blocky status ===")
    print(dns_server.succeed("systemctl status blocky --no-pager || true"))
    print(dns_server.succeed("ss -tulnp | grep -E ':53|:5335|:4000' || true"))
    print(dns_server.succeed("journalctl -u blocky -n 80 --no-pager"))
  '';
}
