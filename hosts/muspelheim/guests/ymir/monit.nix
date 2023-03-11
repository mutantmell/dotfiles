{ config, ... }:
{
  config = {
    networking.firewall.allowedTCPPorts = [
      80
      443
      config.services.loki.configuration.server.http_listen_port
      config.services.prometheus.port
    ];

    services.grafana = {
      enable = true;
      settings = {
        server.domain = "${config.networking.hostName}.local";
      };
    };

    services.prometheus = {
      enable = true;
      port = 9001;
      exporters = {
        node = {
          enable = true;
          enabledCollectors = [ "systemd" ];
          port = 9002;
        };
      };
      scrapeConfigs = [
        {
          job_name = "${config.networking.hostName}_node";
          static_configs = [{
            targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
          }];
        }
        {
          job_name = "jotunheimr_node";
          static_configs = [{
            targets = [ "jotunheimr.local:9001" ];
          }];
        }
        {
          job_name = "jotunheimr_zfs";
          static_configs = [{
            targets = [ "jotunheimr.local:9002" ];
          }];
        }
        {
          job_name = "jotunheimr_smartctl";
          static_configs = [{
            targets = [ "jotunheimr.local:9003" ];
          }];
        }
        {
          job_name = "matrix_smartctl";
          static_configs = [{
            targets = [ "10.100.1.1:9001" ];
          }];
        }

      ];
    };

    services.loki = {
      enable = true;
      configuration = {
        server.http_listen_port = 3030;
        auth_enabled = false;

        ingester = {
          lifecycler = {
            address = "127.0.0.1";
            ring = {
              kvstore = {
                store = "inmemory";
              };
              replication_factor = 1;
            };
            final_sleep = "0s";
          };
          chunk_idle_period = "1h";
          max_chunk_age = "1h";
          chunk_target_size = 999999;
          chunk_retain_period = "30s";
          max_transfer_retries = 0;
        };

        schema_config = {
          configs = [{
            from = "2022-06-06";
            store = "boltdb-shipper";
            object_store = "filesystem";
            schema = "v11";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }];
        };

        storage_config = {
          boltdb_shipper = {
            active_index_directory = "/var/lib/loki/boltdb-shipper-active";
            cache_location = "/var/lib/loki/boltdb-shipper-cache";
            cache_ttl = "24h";
            shared_store = "filesystem";
          };

          filesystem = {
            directory = "/var/lib/loki/chunks";
          };
        };

        limits_config = {
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
        };

        chunk_store_config = {
          max_look_back_period = "0s";
        };

        table_manager = {
          retention_deletes_enabled = false;
          retention_period = "0s";
        };

        compactor = {
          working_directory = "/var/lib/loki";
          shared_store = "filesystem";
          compactor_ring = {
            kvstore = {
              store = "inmemory";
            };
          };
        };
      };
    };
    services.promtail = {
      enable = true;
      configuration = {
        server = {
          http_listen_port = 3031;
          grpc_listen_port = 0;
        };
        positions = {
          filename = "/tmp/positions.yaml";
        };
        clients = let
          loki-port = toString config.services.loki.configuration.server.http_listen_port;
        in [{
          url = "http://127.0.0.1:${loki-port}/loki/api/v1/push";
        }];
        scrape_configs = [{
          job_name = "journal";
          journal = {
            max_age = "12h";
            labels = {
              job = "systemd-journal";
              host = "${config.networking.hostName}_journal";
            };
          };
          relabel_configs = [{
            source_labels = [ "__journal__systemd_unit" ];
            target_label = "unit";
          }];
        }];
      };
    };

    services.nginx.enable = true;
    services.nginx.virtualHosts."${config.services.grafana.settings.server.domain}" = {
      locations."/" = {
        proxyPass = "http://localhost:${toString config.services.grafana.settings.server.http_port}";
        proxyWebsockets = true;
        extraConfig = "proxy_set_header Host $host;";
      };
    };
  };
}
