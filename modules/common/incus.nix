{ config, lib, pkgs, options, ... }:

let
  cfg = config.common.incus;
  impCfg = config.common.impermanence;
  hasIncusManager = options ? incus-manager;
in {
  options.common.incus = {
    enable = lib.mkEnableOption "common incus host options";

    guestDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the guests directory. Each subdirectory is auto-discovered
        as an Incus guest and configured via mk-incus-vm or mk-incus-container.
      '';
    };
  };

  config = lib.mkMerge [
    # Auto-discover guests and populate incus-manager.guests
    (lib.optionalAttrs hasIncusManager (lib.mkIf (cfg.enable && cfg.guestDir != null) (
      let
        guestEntries = builtins.readDir cfg.guestDir;
        mkGuestSystem = name: _type: let
          guestModule = import (cfg.guestDir + "/${name}");

          # Build with the VM builder first to probe incus-guest.type.
          # The VM builder includes all standard modules (sops, common, etc.)
          # so the guest config can reference common.* options.
          vmSystem = pkgs.mmell.lib.builders.mk-incus-vm guestModule;
          guestType = vmSystem.config.incus-guest.type;
          guestMeta = vmSystem.config.incus-guest;

          # If the guest is actually a container, rebuild with the container builder
          builtSystem = if guestType == "vm"
            then vmSystem
            else pkgs.mmell.lib.builders.mk-incus-container guestModule;
        in {
          type = guestType;
          system = builtSystem;
          profile = guestMeta.profile;
          network = guestMeta.network;
          autoStart = guestMeta.autoStart;
        };
      in {
        incus-manager.enable = true;
        incus-manager.guests = builtins.mapAttrs (name: type:
          if type != "directory" then abort "invalid incus guest: ${name}"
          else mkGuestSystem name type
        ) guestEntries;
      }
    )))

    # Persist /var/lib/incus via impermanence
    (lib.mkIf (cfg.enable && impCfg.enable) {
      environment.persistence.${impCfg.persistDir}.directories = [
        "/var/lib/incus"
      ];
    })
  ];
}
