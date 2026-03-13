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

      # Mount the ESP in initrd so systemd-cryptsetup can access the LUKS keyfile.
      # Uses a systemd mount unit (preOpenCommands not supported with systemd initrd).
      boot.initrd.systemd.mounts = [
        {
          where = "/sysroot/boot";
          what = "/dev/disk/by-partlabel/disk-main-ESP";
          type = "vfat";
          options = "ro";
        }
      ];

      # Unmount after cryptsetup so NixOS can mount /boot normally later
      boot.initrd.systemd.services.unmount-esp-keyfile = {
        description = "Unmount ESP after LUKS unlock";
        after = ["cryptsetup.target"];
        wantedBy = ["initrd.target"];
        before = ["initrd-fs.target"];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        script = ''
          umount /sysroot/boot 2>/dev/null || true
        '';
      };

      boot.initrd.luks.devices."cryptroot" = {
        device = "/dev/disk/by-partlabel/disk-main-persist";
        allowDiscards = true;
        keyFile = "/sysroot/boot/secrets/disk.key";
      };

      # Ensure /boot/secrets directory exists on the running system
      system.activationScripts.createBootSecrets = ''
        mkdir -p /boot/secrets
        chmod 700 /boot/secrets
      '';
    })
    (lib.mkIf cfg.impermanence.enable {
      boot.initrd.systemd.services.rollback = {
        description = "Rollback btrfs root subvolume to blank state";
        wantedBy = ["initrd.target"];
        after = ["cryptsetup.target"];
        before = ["sysroot.mount"];
        path = [pkgs.btrfs-progs pkgs.util-linux];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        script = ''
          mkdir -p /mnt
          mount ${cfg.impermanence.device} /mnt -o subvolid=5
          if [ -d /mnt/${cfg.impermanence.subvolume} ]; then
            btrfs subvolume delete /mnt/${cfg.impermanence.subvolume}
          fi
          btrfs subvolume snapshot /mnt/${cfg.impermanence.blankSnapshot} /mnt/${cfg.impermanence.subvolume}
          umount /mnt
        '';
      };
    })
  ]);
}
