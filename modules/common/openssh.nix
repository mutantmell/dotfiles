{
  config,
  options,
  pkgs,
  lib,
  ...
}: let
  cfg = config.common.openssh;
  inherit (pkgs.mmell.lib.data) pki;
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
      default = true;
      description = "Trust the project SSH user CA for certificate authentication.";
    };
    hostCertificate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Present the SSH host certificate if one exists for this host.";
    };
    principals = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {root = ["admin"];};
      description = "Map of unix users to authorized SSH certificate principals.";
    };
  };

  config = let
    hostname = config.networking.hostName;
    hostCerts = pkgs.mmell.lib.data.hostCerts or {};
    hasCert = cfg.hostCertificate && hostCerts ? ${hostname};
  in
    lib.mkIf cfg.enable {
      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = cfg.allowPassword;
          PermitRootLogin = "prohibit-password";
          KbdInteractiveAuthentication = false;
        };
        extraConfig = lib.mkMerge [
          (lib.mkIf cfg.trustedUserCA
            "TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub")
          (lib.mkIf hasCert
            "HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub")
        ];
      };

      environment.etc = lib.mkMerge [
        (lib.optionalAttrs cfg.trustedUserCA {
          "ssh/ssh_user_ca.pub".source = pki.sshUserCA;
        })
        (lib.optionalAttrs hasCert {
          "ssh/ssh_host_ed25519_key-cert.pub" = {
            source = hostCerts.${hostname};
            mode = "0444";
          };
        })
      ];

      # Trust the host CA so SSH between hosts doesn't require TOFU
      programs.ssh.knownHosts."host-ca" = {
        hostNames = ["*.internal" "*.internal.mutantmell.net" "*.mutantmell.net"];
        publicKeyFile = pki.sshHostCA;
        certAuthority = true;
      };

      # Use NixOS-native authorizedPrincipals (writes to /etc/ssh/authorized_principals.d/%u)
      users.users =
        lib.mapAttrs (
          user: principals: {
            openssh.authorizedPrincipals = principals;
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
