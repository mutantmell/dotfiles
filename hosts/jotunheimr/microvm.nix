{ config, pkgs, microvm, ... }:
{
  microvm = rec {
    vms = builtins.mapAttrs (name: type: if type != "directory" then abort "invalid guest: ${name}" else {
      inherit pkgs;
      config = pkgs.mmell.lib.builders.mk-microvm (import (./guests + "/${name}"));
    }) (builtins.readDir ./guests);
    autostart = builtins.attrNames vms;
  };

  # https://github.com/astro/microvm.nix/issues/210#issuecomment-1979680979
  systemd.services = let
    script-name = "rm-skadi-store";
  in {
    "${script-name}" = {
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeScript "rm-image" ''
          #!${pkgs.runtimeShell}
          rm -f /data/guests/skadi/images/store-overlay.img
        '';
      };
    };

    "microvm@skadi" = {
      after = [ "${script-name}.service" ];
      requires = [ "${script-name}.service" ];
    };
  };
}
