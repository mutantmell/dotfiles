{
  config,
  options,
  pkgs,
  lib,
  ...
}: let
  cfg = config.common.openssh;
  inherit (pkgs.mmell.lib.data) pki;
  hasSshUserCA = pki.sshUserCA != null;
in {
  options.common.openssh = {
    enable = lib.mkEnableOption "Common OpenSSH Configuration";
    users = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = ["root"];
    };
    keys = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.enum (
        builtins.attrNames pkgs.mmell.lib.data.keys.ssh
      ));
      default = ["deploy"];
    };
    allowPassword = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    trustedUserCA = lib.mkOption {
      type = lib.types.bool;
      default = hasSshUserCA;
      defaultText = lib.literalExpression "true when lib/common/data/pki/ssh_user_ca.pub exists";
      description = "Trust the project SSH user CA for certificate authentication.";
    };
    principals = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {root = ["admin"];};
      description = "Map of unix users to authorized SSH certificate principals.";
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
      extraConfig = lib.concatStringsSep "\n" (
        lib.optional cfg.trustedUserCA
        "TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub"
        ++ lib.optional (cfg.principals != {})
        "AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u"
      );
    };

    assertions = [
      {
        assertion = cfg.trustedUserCA -> hasSshUserCA;
        message = "common.openssh.trustedUserCA is true but lib/common/data/pki/ssh_user_ca.pub does not exist";
      }
    ];

    environment.etc =
      lib.optionalAttrs cfg.trustedUserCA {
        "ssh/ssh_user_ca.pub".source = pki.sshUserCA;
      }
      // lib.mapAttrs' (
        user: principals:
          lib.nameValuePair "ssh/auth_principals/${user}" {
            text = lib.concatStringsSep "\n" principals + "\n";
            mode = "0444";
          }
      )
      cfg.principals;

    users.extraUsers = builtins.listToAttrs (builtins.map (
        user:
          lib.attrsets.nameValuePair user {
            openssh.authorizedKeys.keys = builtins.map (key: pkgs.mmell.lib.data.keys.ssh.${key}) cfg.keys;
          }
      )
      cfg.users);
  };
}
