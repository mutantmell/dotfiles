{
  config,
  pkgs,
  ...
}: {
  services.keycloak = {
    enable = true;
    settings = {
      http-port = 9080;
      hostname = "https://auth.mutantmell.net";
      proxy-headers = "xforwarded";
      http-enabled = true;
    };
    database.passwordFile = config.sops.secrets."keycloak_password_file".path;
    realmFiles = [./homelab-realm.json];
  };

  # Cap JVM heap to prevent Keycloak from consuming all available RAM
  systemd.services.keycloak.environment.JAVA_OPTS_APPEND = "-Xms256m -Xmx768m";

  networking.firewall.allowedTCPPorts = [80 443];

  environment.etc = {
    "step-ca/data/intermediate_ca.crt" = {
      source = pkgs.mmell.lib.data.pki.intermediate;
      mode = "0444";
    };
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;

    virtualHosts."auth.mutantmell.net" = let
      proxyConfig = ''
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;

        proxy_buffer_size   128k;
        proxy_buffers   4 256k;
        proxy_busy_buffers_size   256k;
      '';
    in {
      forceSSL = true;
      enableACME = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:9080";
        extraConfig = proxyConfig;
      };
    };
  };

  security.acme = {
    defaults = {
      server = "https://basel.internal/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
    certs."auth.mutantmell.net" = {};
  };

  systemd.services.keycloak = {
    before = ["nginx.service"];
    requiredBy = ["nginx.service"];
    serviceConfig = {
      EnvironmentFile = config.sops.templates."keycloak-admin-env".path;
    };
  };

  sops.templates."keycloak-admin-env" = {
    content = ''
      KC_BOOTSTRAP_ADMIN_PASSWORD=${config.sops.placeholder."keycloak_admin_password"}
    '';
  };

  environment.persistence."/persist" = {
    directories = [
      {
        directory = "/var/lib/acme";
        user = "acme";
        group = "acme";
      }
      {
        directory = "/var/lib/postgresql";
        user = "postgres";
        group = "postgres";
      }
    ];
  };
}
