{ config, ... }:
{
  config = {
    networking.firewall.allowedTCPPorts = [ 80 443 9001 ];
    
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
      ];
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
