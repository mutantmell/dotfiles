{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.common.btrfs;
in {
  options.common.btrfs = {
    enable = lib.mkEnableOption "Enable common btrfs options";
    keyfileUnlock = lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption "LUKS unlock via keyfile on ESP";
      };
      default = {};
    };
    impermanence = lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption "btrfs subvolume rollback on boot";
        options.device = lib.mkOption {
          type = lib.types.str;
          default = "/dev/mapper/cryptroot";
          description = "LUKS device path containing the btrfs filesystem";
        };
        options.subvolume = lib.mkOption {
          type = lib.types.str;
          default = "@root";
          description = "Name of the root subvolume to roll back";
        };
        options.blankSnapshot = lib.mkOption {
          type = lib.types.str;
          default = "@blank";
          description = "Name of the blank snapshot to restore from";
        };
      };
      default = {};
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.initrd.systemd.enable = true;
      boot.initrd.supportedFilesystems = ["btrfs"];
    }
    (lib.mkIf cfg.keyfileUnlock.enable {
      boot.initrd.supportedFilesystems = ["vfat"];

      # Use crypttab's keyfile:device syntax so systemd-cryptsetup-generator
      # automatically mounts the ESP, reads the keyfile, and unmounts it.
      # No manual mount units, drop-ins, or unmount services needed.
      boot.initrd.luks.devices."cryptroot" = {
        device = "/dev/disk/by-partlabel/disk-main-persist";
        allowDiscards = true;
        keyFile = "/secrets/disk.key:/dev/disk/by-partlabel/disk-main-ESP";
        keyFileTimeout = 10;
      };

      # Ensure /boot/secrets directory exists on the running system
      system.activationScripts.createBootSecrets = ''
        mkdir -p /boot/secrets
        chmod 700 /boot/secrets
      '';
    })
    (lib.mkIf cfg.impermanence.enable {
      # Stub unit so systemd doesn't report the initrd rollback service as
      # "not-found"/"failed" after switch-root (initrd service state carries
      # over via /run, but the unit file only exists in the initrd).
      systemd.services.rollback = {
        description = "Rollback btrfs root subvolume to blank state (initrd stub)";
        serviceConfig.Type = "oneshot";
        serviceConfig.ExecStart = "/run/current-system/sw/bin/true";
        serviceConfig.RemainAfterExit = true;
      };

      boot.initrd.systemd.services.rollback = {
        description = "Rollback btrfs root subvolume to blank state";
        wantedBy = ["initrd.target"];
        after = ["cryptsetup.target"];
        before = ["sysroot.mount"];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.coreutils}/bin/mkdir -p /mnt
          ${pkgs.util-linux}/bin/mount ${cfg.impermanence.device} /mnt -o subvolid=5
          if [ -d /mnt/${cfg.impermanence.subvolume} ]; then
            ${pkgs.btrfs-progs}/bin/btrfs subvolume delete /mnt/${cfg.impermanence.subvolume}
          fi
          ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot /mnt/${cfg.impermanence.blankSnapshot} /mnt/${cfg.impermanence.subvolume}
          ${pkgs.util-linux}/bin/umount /mnt
        '';
      };
    })
  ]);
}
