{
  config,
  lib,
  ...
}: let
  cfg = config.common.impermanence;
in {
  options.common.impermanence = {
    enable = lib.mkEnableOption "common impermanence options";

    persistDir = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = "Top-level persistent directory for impermanence.";
    };

    directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/etc/nixos"
        "/var/log"
        "/var/lib/nixos"
        "/var/lib/systemd/coredump"
      ];
      description = "Baseline directories to persist.";
    };

    files = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/ssh/ssh_host_rsa_key"
        "/etc/ssh/ssh_host_rsa_key.pub"
        "/root/.ssh/known_hosts"
      ];
      description = "Baseline files to persist.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.persistence.${cfg.persistDir} = {
      hideMounts = true;
      inherit (cfg) directories files;
    };

    # Copy persisted machine-id into place before systemd starts (which would
    # create a new one), avoiding the race with impermanence bind mounts.
    boot.initrd.postMountCommands = lib.mkBefore ''
      if [ -f /mnt-root${cfg.persistDir}/etc/machine-id ]; then
        mkdir -p /mnt-root/etc
        cp /mnt-root${cfg.persistDir}/etc/machine-id /mnt-root/etc/machine-id
      fi
    '';

    # On first boot, save the generated machine-id to persist for future boots.
    system.activationScripts.persist-machine-id = lib.stringAfter ["etc"] ''
      if [ ! -f ${cfg.persistDir}/etc/machine-id ] && [ -f /etc/machine-id ]; then
        mkdir -p ${cfg.persistDir}/etc
        cp /etc/machine-id ${cfg.persistDir}/etc/machine-id
      fi
    '';

    # impermanence creates /var/lib/private with 0755 but DynamicUser services require 0700
    # (https://github.com/nix-community/impermanence/issues/254)
    systemd.tmpfiles.rules = ["d /var/lib/private 0700 root root"];

    fileSystems.${cfg.persistDir}.neededForBoot = true;
  };
}
