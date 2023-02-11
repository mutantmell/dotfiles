{ config, pkgs, ... }:
{
  services.matrix-synapse = {
    enable = true;
    settings = {
      server_name = config.networking.domain;
      listeners = [
        {
          port = 8008;
          bind_addresses = [
            "::1"
            "127.0.0.1"
          ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            { names = [ "client" "federation" ]; compress = false; }
          ];
        }
      ];
      database.name = "psycopg2";
      presence.enabled = false;
    };
  };
  
  services.postgresql.enable = true;
  services.postgresql.initialScript = pkgs.writeText "synapse-init.sql" ''
    CREATE ROLE "matrix-synapse" WITH LOGIN PASSWORD 'synapse';
    CREATE DATABASE "matrix-synapse" WITH OWNER "matrix-synapse"
      TEMPLATE template0
      LC_COLLATE = "C"
      LC_CTYPE = "C";
  '';

  systemd.services."synapse-compress" = {
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = config.sops.secrets.synapse-compress-env.path;
    };
    path = with pkgs; [
      bash
      matrix-synapse-tools.rust-synapse-compress-state
      postgresql
    ];
    script = ''
      #!/usr/bin/env bash

      synapse_auto_compressor -p postgresql://postgres:$POSTGRES_PASS@localhost/matrix-synapse -c 500 -n 1000
      psql --host=localhost --port=5432 --dbname=matrix-synapse --username=postgres -c 'VACUUM FULL VERBOSE'
    '';
  };
  systemd.timers."synapse-compress" = {
    wantedBy = [ "timers.target" ];
    partOf = [ "synapse-compress.service" ];
    timerConfig = {
      OnCalendar = "Sun,Wed *-*-* 02:00:00";
      Unit = "synapse-compress.service";
    };
  };
}
