# Pure Nix evaluation test for router6's Blocky DNS config.
#
# Asserts on services.blocky.settings produced by enabling
# router6.dns.blocking in a minimal router eval. Catches the failure modes
# that bit us during DNS consolidation: wrong bind, wrong backend, accidental
# loss of metrics/denylists, and opt-out subnets falling back to the default
# blocking group.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-dns-blocking-config.nix
# Or:  nix build .#checks.x86_64-linux.router6-dns-blocking-config
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  denylist = pkgs.writeText "ads-denylist" ''
    ads.example
  '';

  eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ../../modules/router6
      {
        boot.loader.grub.device = "nodev";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        nixpkgs.pkgs = pkgs;
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "25.11";
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
            upstream = ["10.0.20.2"];
            upstreamPolicy = "stub";
            enableDNSSEC = false;
            blocking = {
              enable = true;
              denylists.ads = [denylist];
              conditionalDomains = ["internal" "internal.mutantmell.net"];
            };
          };

          topology = {
            wan = {
              hardwareName = "eth0";
              network = {
                type = "dhcp";
                zone = "external";
                nat.enable = true;
              };
            };
            lan = {
              hardwareName = "eth1";
              network = {
                type = "static";
                addresses = ["10.0.10.1/24" "fdc6:55f2:0a5e:a::1/64"];
                zone = "trusted";
                subnetId = 10;
              };
            };
            guest = {
              hardwareName = "eth2";
              network = {
                type = "static";
                addresses = ["10.0.11.1/24"];
                zone = "trusted";
                subnetId = 11;
                dnsBlock = false;
              };
            };
          };
        };
      }
    ];
  };

  blocky = eval.config.services.blocky;
  kresd = eval.config.services.kresd;
  dnsListeners = lib.splitString "," blocky.settings.ports.dns;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  tests = [
    (assertTrue "blocky is enabled"
      blocky.enable)

    (assertTrue "blocky binds loopback and DNS-serving gateway addresses"
      (lib.all (listener: lib.elem listener dnsListeners) [
        "127.0.0.1:53"
        "[::1]:53"
        "10.0.10.1:53"
        "[fdc6:55f2:0a5e:a::1]:53"
        "10.0.11.1:53"
      ]))

    (assertTrue "blocky does not wildcard-bind DNS"
      (!lib.hasInfix "0.0.0.0:53" blocky.settings.ports.dns))

    (assertTrue "blocky http (metrics + API) binds loopback only"
      (lib.hasPrefix "127.0.0.1:" blocky.settings.ports.http))

    (assertTrue "blocky upstream points at local kresd backend on :5335"
      (blocky.settings.upstreams.groups.default == ["127.0.0.1:5335"]))

    (assertTrue "blocky has at least one denylist source"
      (lib.length (blocky.settings.blocking.denylists.ads or []) >= 1))

    (assertTrue "blocky default client group is blocked"
      (blocky.settings.blocking.clientGroupsBlock.default == ["ads"]))

    (assertTrue "blocky opt-out subnet maps to non-empty noblock group"
      (blocky.settings.blocking.clientGroupsBlock."10.0.11.0/24" == ["noblock"]))

    (assertTrue "blocky noblock group has an empty denylist source"
      (lib.length blocky.settings.blocking.denylists.noblock == 1))

    (assertTrue "blocky prometheus enabled"
      blocky.settings.prometheus.enable)

    # Blocky short-circuits special-use TLDs (.internal, .local, etc.) to
    # NXDOMAIN. Without a conditional upstream, the homelab's entire
    # *.internal split-horizon naming breaks. Guard against regression.
    (assertTrue "blocky conditional upstream covers internal."
      ((blocky.settings.conditional.mapping.internal or null) != null))

    (assertTrue "blocky conditional upstream covers internal.mutantmell.net"
      ((blocky.settings.conditional.mapping."internal.mutantmell.net" or null) != null))

    (assertTrue "blocky conditional fallbackUpstream is disabled"
      (!blocky.settings.conditional.fallbackUpstream))

    (assertTrue "kresd still enabled"
      kresd.enable)

    (assertTrue "kresd retreats to loopback backend when blocking is enabled"
      (kresd.listenPlain == ["127.0.0.1:5335" "[::1]:5335"]))

    (assertTrue "resolved is disabled by router6 DNS"
      (!eval.config.services.resolved.enable))

    (assertTrue "AdGuard is not enabled"
      (!(eval.config.services.adguardhome.enable or false)))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-dns-blocking-config" {} ''
      echo "All ${toString (builtins.length tests)} router6-dns-blocking-config tests passed"
      echo "PASS" > $out
    ''
  else throw "router6-dns-blocking-config tests failed"
