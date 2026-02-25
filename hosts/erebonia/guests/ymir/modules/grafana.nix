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
