{config, ...}: {
  networking.firewall.allowedTCPPorts = [80 443];

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3000;
        domain = "tharbad.internal";
        root_url = "https://tharbad.internal/";
      };
      security = {
        admin_user = "admin";
        admin_password = "$__file{${config.sops.secrets."grafana-admin-password".path}}";
        secret_key = "$__file{${config.sops.secrets."grafana-secret-key".path}}";
      };
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          url = "http://localhost:9090";
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
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    virtualHosts."tharbad.internal" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
      };
    };
  };

  security.acme = {
    defaults = {
      server = "https://basel.internal/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/grafana";
      user = "grafana";
      inherit (config.users.users.grafana) group;
    }
  ];
}
