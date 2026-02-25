{ config, lib, ... }:

let
  cfg = config.promtail-client;
in {
  options.promtail-client = {
    enable = lib.mkEnableOption "Promtail log shipping to Loki";
    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://ymir.internal:3100/loki/api/v1/push";
      description = "Loki push API endpoint URL";
    };
  };

  config = lib.mkIf cfg.enable {
    services.promtail = {
      enable = true;
      configuration = {
        server = {
          http_listen_port = 0;
          grpc_listen_port = 0;
        };
        positions.filename = "/tmp/positions.yaml";
        clients = [{
          url = cfg.lokiUrl;
        }];
        scrape_configs = [{
          job_name = "journal";
          journal = {
            max_age = "12h";
            labels = {
              job = "systemd-journal";
              host = config.networking.hostName;
            };
          };
          relabel_configs = [{
            source_labels = [ "__journal__systemd_unit" ];
            target_label = "unit";
          }];
        }];
      };
    };
  };
}
