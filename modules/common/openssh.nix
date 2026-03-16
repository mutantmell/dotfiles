{
  config,
  options,
  pkgs,
  lib,
  ...
}: let
  cfg = config.common.openssh;
  inherit (pkgs.mmell.lib.data) sshCA;
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
    hostCertificate = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = let
        hostname = config.networking.hostName;
      in
        if sshCA != null && sshCA ? hostCerts && sshCA.hostCerts ? ${hostname}
        then sshCA.hostCerts.${hostname}
        else null;
      defaultText = lib.literalExpression "auto-discovered from hostname in ssh-ca.json";
      description = "SSH host certificate string. Auto-discovered by hostname if available.";
    };
    trustedUserCA = lib.mkOption {
      type = lib.types.bool;
      default = sshCA != null && sshCA ? userCA;
      defaultText = lib.literalExpression "true when SSH user CA exists in ssh-ca.json";
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
        lib.optional (cfg.hostCertificate != null)
        "HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub"
        ++ lib.optional cfg.trustedUserCA
        "TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub"
        ++ lib.optional (cfg.principals != {})
        "AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u"
      );
    };

    assertions = [
      {
        assertion = cfg.trustedUserCA -> (sshCA != null && sshCA ? userCA);
        message = "common.openssh.trustedUserCA is true but ssh-ca.json is missing or has no userCA";
      }
    ];

    environment.etc =
      lib.optionalAttrs (cfg.hostCertificate != null) {
        "ssh/ssh_host_ed25519_key-cert.pub".text = cfg.hostCertificate;
      }
      // lib.optionalAttrs (cfg.trustedUserCA && sshCA != null) {
        "ssh/ssh_user_ca.pub".text = sshCA.userCA;
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
