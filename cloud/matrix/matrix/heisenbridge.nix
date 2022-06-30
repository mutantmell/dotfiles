{ config, pkgs, lib, ... }:

{
  services.heisenbridge = {
    enable = true;
    homeserver = "http://localhost:8008";
    namespaces = {
      users = [
        {
          regex = "@irc_.*";
          exclusive = true;
        }
      ];
      aliases = [ ];
      rooms = [ ];
    };
  };

  services.matrix-synapse = {
    settings.app_service_config_files = [
      "/var/lib/heisenbridge/registration.yml"
    ];
  };
}
