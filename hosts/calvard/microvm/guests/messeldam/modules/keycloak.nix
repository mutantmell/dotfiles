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
      http-relative-path = "/auth";
      proxy-headers = "forwarded|xforwarded";
      http-enabled = true;
      hostname-admin = "https://messeldam.internal.mutantmell.net";
    };
    database.passwordFile = config.sops.secrets."keycloak_password_file".path;
    realmFiles = [./homelab-realm.json];
  };

  # Cap JVM heap to prevent Keycloak from consuming all available RAM
  systemd.services.keycloak.environment.JAVA_OPTS_APPEND = "-Xms256m -Xmx768m";

  networking.firewall.allowedTCPPorts = [80 443];

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;

    virtualHosts."auth.mutantmell.net" = {
      forceSSL = true;
      enableACME = true;

      locations."/auth" = {
        proxyPass = "http://127.0.0.1:9080";
        extraConfig = ''
          proxy_set_header X-Forwarded-For $proxy_protocol_addr;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;

          proxy_buffer_size   128k;
          proxy_buffers   4 256k;
          proxy_busy_buffers_size   256k;
        '';
      };
    };

    virtualHosts."messeldam.internal.mutantmell.net" = {
      forceSSL = true;
      useACMEHost = "auth.mutantmell.net";

      locations."/auth" = {
        proxyPass = "http://127.0.0.1:9080";
        extraConfig = ''
          proxy_set_header X-Forwarded-For $proxy_protocol_addr;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;

          proxy_buffer_size   128k;
          proxy_buffers   4 256k;
          proxy_busy_buffers_size   256k;
        '';
      };
    };
  };

  environment.etc = {
    "step-ca/data/intermediate_ca.crt" = {
      source = pkgs.mmell.lib.data.certs.intermediate;
      mode = "0444";
    };
  };

  security.acme = {
    defaults = {
      server = "https://basel.internal/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
    certs."auth.mutantmell.net" = {
      extraDomainNames = ["messeldam.internal.mutantmell.net"];
    };
  };

  systemd.services = {
    "keycloak".before = ["nginx.service"];
    "keycloak".requiredBy = ["nginx.service"];
  };

  environment.persistence."/persist" = {
    directories = [
      {
        directory = "/var/lib/postgresql";
        user = "postgres";
        group = "postgres";
      }
    ];
  };
}
