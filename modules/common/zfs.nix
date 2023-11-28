{ config, options, pkgs, lib, ... }:

let
  cfg = config.common.zfs;
in {
  options.common.zfs = {
    remoteUnlock = lib.mkOption {
      type = lib.type.attrsOf {
        enable = lib.mkEnableOption "Remote Unlock via SSH";
        hostkey = lib.mkOption {
          type = lib.type.path;
          default = /etc/ssh/ssh_host_ed25519_key;
        };
      };
    };
  };

  config = lib.mkIf cfg.remoteUnlock.enable {
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
  };
}
