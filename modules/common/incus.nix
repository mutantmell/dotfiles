{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
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

          # Two-pass type probing: we need to read incus-guest.type from the
          # evaluated guest config to decide which builder to use, but guest
          # configs reference common.* options (e.g. common.openssh) that
          # require the full module set — so we can't use a lightweight
          # evaluation. Instead, we build with the VM builder first (which
          # includes all standard modules) just to read the guest metadata.
          # If the guest turns out to be a container, we rebuild with the
          # container builder. Nix's laziness ensures that VM-specific build
          # artifacts (qcow2 images, etc.) are never materialized for
          # container guests — only the config.incus-guest attrset is forced.
          vmSystem = pkgs.mmell.lib.builders.mk-incus-vm guestModule;
          guestType = vmSystem.config.incus-guest.type;
          guestMeta = vmSystem.config.incus-guest;

          builtSystem =
            if guestType == "vm"
            then vmSystem
            else pkgs.mmell.lib.builders.mk-incus-container guestModule;
        in {
          type = guestType;
          system = builtSystem;
          inherit (guestMeta) profile;
          inherit (guestMeta) network;
          inherit (guestMeta) autoStart;
        };
      in {
        incus-manager.enable = true;
        incus-manager.guests =
          builtins.mapAttrs (
            name: type:
              if type != "directory"
              then abort "invalid incus guest: ${name}"
              else mkGuestSystem name type
          )
          guestEntries;
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
