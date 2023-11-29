{ config, options, pkgs, lib, ... }:

let
  cfg = config.common.zfs;
in {
  options.common.zfs = {
    enable = lib.mkEnableOption "Enable common ZFS options";
    remoteUnlock = lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption "Remote Unlock via SSH";
        options.hostkey = lib.mkOption {
          type = lib.types.path;
          default = /etc/ssh/initrd_ssh_host_ed25519_key;
        };
      };
      default = {};
    };
    impermanence = lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption "Impermanence common options";
        options.dataset = lib.mkOption {
          type = lib.types.str;
          description = "zfs dataset to rollback on boot";
        };
        options.snapshot = lib.mkOption {
          type = lib.types.str;
          default = "blank";
          description = "zfs snapshot to rollback to";
        };
      };
      default = {};
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
    }
    (lib.mkIf cfg.remoteUnlock.enable {
      boot.initrd.network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          hostKeys = [ cfg.remoteUnlock.hostkey ];
          authorizedKeys = builtins.map (key:
            pkgs.mmell.lib.data.keys.ssh.${key}
          ) ["deploy" "home"];
        };
        #postCommands = ''
        #  zpool import -a
        #  echo "zfs load-key -a; killall zfs" >> /root/.profile
        #'';
      };
    })
    (lib.mkIf cfg.impermanence.enable {
      boot.initrd.postDeviceCommands = lib.mkAfter ''
        zfs rollback -r ${cfg.impermanence.dataset}@${cfg.impermanence.snapshot}
      '';
    })
  ]);
}
