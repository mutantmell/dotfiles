{config, ...}: {
  networking.firewall.allowedTCPPorts = [3100];

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;

      server = {
        http_listen_port = 3100;
        http_listen_address = "127.0.0.1";
      };

      common = {
        path_prefix = "/var/lib/loki";
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store = "inmemory";
        };
        replication_factor = 1;
      };

      schema_config.configs = [
        {
          from = "2025-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];

      storage_config.filesystem.directory = "/var/lib/loki/chunks";

      limits_config = {
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
      };
    };
  };

  # Reverse proxy: expose only the push API on port 3100 to the network.
  # Loki itself is bound to 127.0.0.1, so /metrics and query endpoints
  # are only reachable locally (by Prometheus and Perses).
  services.nginx.virtualHosts."loki" = {
    listen = [
      {
        addr = "0.0.0.0";
        port = 3100;
      }
    ];
    locations."/loki/api/v1/push" = {
      proxyPass = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}";
    };
    locations."/" = {
      return = "404";
    };
  };

  # Local Promtail — ship tharbad's own logs to localhost Loki
  promtail-client = {
    enable = true;
    lokiUrl = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/loki";
      user = "loki";
      group = "loki";
    }
  ];
}
