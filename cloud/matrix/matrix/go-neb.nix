{ config, pkgs, lib, ... }:

with lib;

# Adapted from https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/go-neb.nix
# Using a fork for now to enable configuration via endpoints, because that's more reproducible
let
  cfg = config.services.go-neb-bot;
in {
  options.services.go-neb-bot = {
    enable = mkEnableOption "Extensible matrix bot written in Go";

    bindAddress = mkOption {
      type = types.str;
      description = "Port (and optionally address) to listen on.";
      default = ":4050";
    };

    baseUrl = mkOption {
      type = types.str;
      description = "Public-facing endpoint that can receive webhooks.";
    };

    databaseUrl = mkOption {
      type = types.str;
      description = "Location of the database file.  One will be created if it does not exist.";
      default = "go-neb.db";
    };

  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ sqlite ];

    users.users.go-neb = {
      group = "go-neb";
      home = "/var/lib/go-neb";
      createHome = true;
      shell = "${pkgs.bash}/bin/bash";
      isSystemUser = true;
    };
    users.groups.go-neb = {
    };

    systemd.services.go-neb-bot = {
      description = "Extensible matrix bot written in Go";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        BASE_URL = cfg.baseUrl;
        BIND_ADDRESS = cfg.bindAddress;
        DATABASE_URL = cfg.databaseUrl;
        DATABASE_TYPE = "sqlite3";
      };

      serviceConfig = {
        ExecStart = "${pkgs.go-neb}/bin/go-neb";
        User = "go-neb";
        Group = "go-neb";
        WorkingDirectory = "/var/lib/go-neb"; # TODO: make this reference the user's home dir
      };
    };
  };
}
