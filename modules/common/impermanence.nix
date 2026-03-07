{ config, lib, ... }:

let
  cfg = config.common.impermanence;
in {
  options.common.impermanence = {
    enable = lib.mkEnableOption "common impermanence options";

    persistDir = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = "Top-level persistent directory for impermanence.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.persistence.${cfg.persistDir} = {
      hideMounts = true;
      directories = [
        "/etc/nixos"
        "/var/log"
        "/var/lib/nixos"
        "/var/lib/systemd/coredump"
      ];
      files = [
        "/etc/machine-id"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/ssh/ssh_host_rsa_key"
        "/etc/ssh/ssh_host_rsa_key.pub"
        "/root/.ssh/known_hosts"
      ];
    };

    fileSystems.${cfg.persistDir}.neededForBoot = true;
  };
}
