{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  cfg = config.common.microvm;
  impCfg = config.common.impermanence;
  # microvm.vms only exists when the microvm host module is loaded.
  # These checks use `options` (not `config`) to avoid infinite recursion
  # and prevent registering definitions for options that don't exist.
  isMicrovmHost = options ? microvm && options.microvm ? vms;
in {
  options.common.microvm = {
    enable = lib.mkEnableOption "common microvm host options";
    uid = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        Stable UID for the microvm user. Pinned so that deploy scripts can
        chown guest directories (e.g. /persist/guests/*/images) before the
        first NixOS boot. The kvm group GID (302) is already stable in NixOS.
      '';
    };
    guestDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the guests directory. Each subdirectory is auto-discovered
        as a microVM guest and configured via mk-microvm.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      users.users.microvm.uid = cfg.uid;
    })

    # microvm.vms, microvm.autostart — requires microvm host module
    (lib.optionalAttrs isMicrovmHost (lib.mkIf (cfg.enable && cfg.guestDir != null) (
      let
        guestEntries = builtins.readDir cfg.guestDir;
      in {
        microvm = rec {
          vms =
            builtins.mapAttrs (
              name: type:
                if type != "directory"
                then abort "invalid guest: ${name}"
                else {
                  inherit pkgs;
                  config = pkgs.mmell.lib.builders.mk-microvm (import (cfg.guestDir + "/${name}"));
                }
            )
            guestEntries;
          autostart = builtins.attrNames vms;
        };

        # Ensure virtiofs share directories exist before microVMs start
        systemd.tmpfiles.rules = builtins.map (
          name: "d ${impCfg.persistDir}/guests/${name}/static 0755 root root -"
        ) (builtins.attrNames guestEntries);

        environment.systemPackages = [
          pkgs.mmell.mk-volume
        ];
      }
    )))

    # Persist microvm state via impermanence
    (lib.mkIf (cfg.enable && cfg.guestDir != null && impCfg.enable) {
      environment.persistence.${impCfg.persistDir}.directories = [
        {
          directory = "/var/lib/microvms";
          user = "microvm";
          group = "kvm";
        }
      ];
    })
  ];
}
