# Pure Nix evaluation test for phantasma's Blocky DNS config.
#
# Asserts on services.blocky.settings produced by importing phantasma's
# dns module into a minimal NixOS eval. Catches the failure modes that
# bit us during AdGuard debugging: wrong bind, wrong upstream, accidental
# loss of metrics or denylists.
#
# Run: nix-instantiate --eval --strict tests/lib/blocky-config.nix
# Or:  nix build .#checks.x86_64-linux.blocky-config
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ../../hosts/thebeyond/microvm/guests/phantasma/modules/dns.nix
      {
        boot.loader.grub.device = "nodev";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        nixpkgs.pkgs = pkgs;
        system.stateVersion = "25.11";
      }
    ];
  };

  blocky = eval.config.services.blocky;
  unbound = eval.config.services.unbound;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  tests = [
    (assertTrue "blocky is enabled"
      blocky.enable)

    (assertTrue "blocky binds 0.0.0.0:53"
      (blocky.settings.ports.dns == "0.0.0.0:53"))

    (assertTrue "blocky http (metrics + API) binds loopback only"
      (lib.hasPrefix "127.0.0.1:" blocky.settings.ports.http))

    (assertTrue "blocky upstream points at local Unbound on :5335"
      (blocky.settings.upstreams.groups.default == ["127.0.0.1:5335"]))

    (assertTrue "blocky has at least one denylist source"
      (lib.length (blocky.settings.blocking.denylists.ads or []) >= 1))

    (assertTrue "blocky default client group is blocked"
      (blocky.settings.blocking.clientGroupsBlock.default == ["ads"]))

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

    (assertTrue "unbound still enabled"
      unbound.enable)

    (assertTrue "unbound still listens on 127.0.0.1"
      (lib.elem "127.0.0.1" unbound.settings.server.interface))

    (assertTrue "unbound still on port 5335"
      (unbound.settings.server.port == 5335))

    (assertTrue "internal. local-zone preserved"
      (lib.any (z: lib.hasInfix "\"internal.\" static" z) unbound.settings.server.local-zone))

    (assertTrue "resolved is disabled"
      (!eval.config.services.resolved.enable))

    (assertTrue "AdGuard is not enabled"
      (!(eval.config.services.adguardhome.enable or false)))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "blocky-config" {} ''
      echo "All ${toString (builtins.length tests)} blocky-config tests passed"
      echo "PASS" > $out
    ''
  else throw "blocky-config tests failed"
