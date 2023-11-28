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
          default = /etc/ssh/ssh_host_ed25519_key;
        };
      };
      default = {};
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
    })
    (lib.mkIf cfg.remoteUnlock.enable {
      boot.initrd.network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          hostKeys = [ cfg.remoteUnlock.hostkey ];
          authorizedKeys = builtins.map (key:
            pkgs.mmell.lib.data.keys.ssh.${key}
          ) [
            "deploy" "home"
          ];
        };
        postCommands = ''
        zpool import -a
        echo "zfs load-key -a; killall zfs" >> /root/.profile
      '';
      };
    })
  ];
}
