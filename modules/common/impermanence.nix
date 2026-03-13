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
        "/etc/machine-id"
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

    # impermanence creates /var/lib/private with 0755 but DynamicUser services require 0700
    # (https://github.com/nix-community/impermanence/issues/254)
    systemd.tmpfiles.rules = ["d /var/lib/private 0700 root root"];

    fileSystems.${cfg.persistDir}.neededForBoot = true;
  };
}
