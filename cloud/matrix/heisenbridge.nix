{ config, pkgs, lib, ... }:


let
  secrets = import ./secrets.nix;
  heisenbridge_conf = pkgs.writeTextFile {
    name = "heisenbridge-registration.yaml";
    executable = false;
    destination = "/heisenbridge/heisenbridge-registration.yaml";
    text = ''
      id: heisenbridge
      url: http://127.0.0.1:9898
      as_token: ${secrets.heisenbridge.as_token};
      hs_token: ${secrets.heisenbridge.hs_token};
      rate_limited: false
      sender_localpart: heisenbridge
      namespaces:
        users:
        - regex: '@irc_.*'
          exclusive: true
        aliases: []
        rooms: []
      '';
  };
  heisenbridge_conf_path = "${heisenbridge_conf}//heisenbridge/heisenbridge-registration.yaml";
in {
  users = {
    users.heisenbridge = {
      group = "heisenbridge";
      isSystemUser = true;
    };
    groups.heisenbridge = {
    };
  };


  systemd.services.heisenbridge = {
    after = [ "matrix-synapse.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = ''
          ${pkgs.heisenbridge}/bin/heisenbridge \
            --config ${heisenbridge_conf_path} \
            --uid heisenbridge \
            --gid heisenbridge \
            http://localhost:8008
        '';
              Restart = "on-failure";
    };
  };

  services.matrix-synapse = {
    settings.app_service_config_files = [
      heisenbridge_conf_path
    ];
  };
}
