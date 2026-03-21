{
  pkgs,
  config,
  ...
}: let
  yaml = (pkgs.formats.yaml {}).generate;

  project = yaml "project.yaml" {
    kind = "Project";
    metadata.name = "monitoring";
    spec.display.name = "Monitoring";
  };

  promDatasource = yaml "global-prometheus.yaml" {
    kind = "GlobalDatasource";
    metadata.name = "prometheus";
    spec = {
      default = true;
      plugin = {
        kind = "PrometheusDatasource";
        spec.proxy = {
          kind = "HTTPProxy";
          spec.url = "http://localhost:${toString config.services.prometheus.port}";
        };
      };
    };
  };

  lokiDatasource = yaml "global-loki.yaml" {
    kind = "GlobalDatasource";
    metadata.name = "loki";
    spec = {
      default = false;
      plugin = {
        kind = "LokiDatasource";
        spec.proxy = {
          kind = "HTTPProxy";
          spec.url = "http://localhost:${toString config.services.loki.configuration.server.http_listen_port}";
        };
      };
    };
  };

  adminBinding = yaml "global-admin-binding.yaml" {
    kind = "GlobalRoleBinding";
    metadata.name = "oidc-admins";
    spec = {
      role = "admin";
      subjects = [
        {
          kind = "User";
          name = "malaguy";
        }
      ];
    };
  };

  provisioningDir = pkgs.runCommand "perses-provisioning" {} ''
    mkdir -p $out
    cp ${project} $out/project.yaml
    cp ${promDatasource} $out/global-prometheus.yaml
    cp ${lokiDatasource} $out/global-loki.yaml
    cp ${adminBinding} $out/global-admin-binding.yaml
    cp ${./dashboards}/*.yaml $out/
  '';
in {
  networking.firewall.allowedTCPPorts = [80 443];

  services.perses = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 8080;
    settings = {
      security = {
        enable_auth = true;
        encryption_key._secret = config.sops.secrets."perses-encryption-key".path;
        authentication.providers.oidc = [
          {
            slug_id = "keycloak";
            name = "Keycloak";
            client_id = "perses";
            client_secret._secret = config.sops.secrets."perses-oidc-client-secret".path;
            issuer = "https://auth.mutantmell.net/realms/homelab";
            redirect_uri = "https://tharbad.internal/api/auth/providers/oidc/keycloak/callback";
            scopes = ["openid" "profile" "email" "groups"];
          }
        ];
      };
      database.file = {
        folder = "/var/lib/perses/data";
        extension = "yaml";
      };
      provisioning.folders = ["${provisioningDir}"];
      frontend.explorer.enable = true;
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
        proxyPass = "http://127.0.0.1:8080";
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
      directory = "/var/lib/acme";
      user = "acme";
      group = "acme";
    }
    "/var/lib/private/perses"
  ];
}
