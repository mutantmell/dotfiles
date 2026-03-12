{config, ...}: {
  networking.firewall.allowedTCPPorts = [3100];

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;

      server.http_listen_port = 3100;

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

  # Local Promtail — ship tharbad's own logs to localhost Loki
  promtail-client = {
    enable = true;
    lokiUrl = "http://127.0.0.1:3100/loki/api/v1/push";
  };
}
