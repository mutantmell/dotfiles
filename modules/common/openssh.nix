{ config, options, pkgs, lib, ... }:

let
  cfg = config.common.openssh;
in {
  options.common.openssh = {
    enable = lib.mkEnableOption "Common OpenSSH Configuration";
    users = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "root" ];
    };
    keys = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.enum (
        builtins.attrNames pkgs.mmell.lib.data.keys.ssh
      ));
      default = [ "deploy" ];
    };
    allowPassword = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = cfg.allowPassword;
        PermitRootLogin = "prohibit-password";
        KbdInteractiveAuthentication = false;
      };
    };

    users.extraUsers = builtins.listToAttrs (builtins.map (user:
      lib.attrsets.nameValuePair user {
        openssh.authorizedKeys.keys = builtins.map (key: pkgs.mmell.lib.data.keys.ssh.${key}) cfg.keys;
      }
    ) cfg.users);
  };
}
