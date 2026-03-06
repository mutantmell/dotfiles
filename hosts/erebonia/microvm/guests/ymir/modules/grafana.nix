{ config, ... }:
{
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  services.grafana = {
    enable = true;
    settings = {
      server.domain = "${config.networking.hostName}.internal";
    };
    provision.datasources.settings.datasources = [
      {
        name = "Prometheus";
        type = "prometheus";
        url = "http://localhost:${toString config.services.prometheus.port}";
        isDefault = true;
      }
      {
        name = "Loki";
        type = "loki";
        url = "http://localhost:3100";
      }
      {
        name = "Alertmanager";
        type = "alertmanager";
        url = "http://localhost:9093";
        jsonData.implementation = "prometheus";
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

  environment.persistence."/persist".directories = [
    {
      directory = toString config.services.grafana.dataDir;
      user = "grafana";
      group = config.users.users.grafana.group;
    }
  ];
}
