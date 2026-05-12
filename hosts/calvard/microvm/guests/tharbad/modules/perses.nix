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
          # vmsingle exposes a PromQL-compatible HTTP API (MetricsQL superset).
          spec.url = "http://localhost:8428";
        };
      };
    };
  };

  vlDatasource = yaml "global-victorialogs.yaml" {
    kind = "GlobalDatasource";
    metadata.name = "victorialogs";
    spec = {
      default = false;
      plugin = {
        kind = "VictoriaLogsDatasource";
        spec.proxy = {
          kind = "HTTPProxy";
          spec.url = "http://localhost:9428";
        };
      };
    };
  };

  adminRole = yaml "global-admin-role.yaml" {
    kind = "GlobalRole";
    metadata.name = "admin";
    spec.permissions = [
      {
        actions = ["*"];
        scopes = ["*"];
      }
    ];
  };

  adminBinding = yaml "global-admin-binding.yaml" {
    kind = "GlobalRoleBinding";
    metadata.name = "oidc-admins";
    spec = {
      role = "admin";
      subjects = [
        {
          kind = "User";
          name = "malaguy"; # email-prefix (perses #3851 workaround)
        }
        {
          kind = "User";
          name = "mutantmell"; # preferred_username (after #3851 is fixed)
        }
      ];
    };
  };

  provisioningDir = pkgs.symlinkJoin {
    name = "perses-provisioning";
    paths = [
      (pkgs.linkFarm "perses-generated" [
        {
          name = "project.yaml";
          path = project;
        }
        {
          name = "global-prometheus.yaml";
          path = promDatasource;
        }
        {
          name = "global-victorialogs.yaml";
          path = vlDatasource;
        }
        {
          name = "global-admin-role.yaml";
          path = adminRole;
        }
        {
          name = "global-admin-binding.yaml";
          path = adminBinding;
        }
      ])
      ./dashboards
    ];
  };
in {
  networking.firewall.allowedTCPPorts = [80 443];

  # Perses fatally exits if it can't reach the OIDC provider (Keycloak on
  # messeldam) at startup. Give it time to retry during boot while Keycloak
  # is still coming up.
  systemd.services.perses = {
    serviceConfig = {
      RestartSec = "5s";
    };
    unitConfig = {
      StartLimitIntervalSec = 300;
      StartLimitBurst = 20;
    };
  };

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
            redirect_uri = "https://perses.internal/api/auth/providers/oidc/keycloak/callback";
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
    virtualHosts."perses.internal" = {
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
