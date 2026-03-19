{
  config,
  pkgs,
  lib,
  ...
}: let
  certDomain = "auth.mutantmell.net";
  certDir = "/var/lib/step-tls/${certDomain}";
  certFile = "${certDir}/cert.pem";
  keyFile = "${certDir}/key.pem";
  caUrl = "https://basel.internal";
  caRoot = "/etc/ssl/certs/ca-certificates.crt";
in {
  services.keycloak = {
    enable = true;
    settings = {
      http-port = 9080;
      hostname = "https://${certDomain}";
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

  # Trust the internal root CA
  security.pki.certificateFiles = [pkgs.mmell.lib.data.pki.root];

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;

    virtualHosts.${certDomain} = let
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
      sslCertificate = certFile;
      sslCertificateKey = keyFile;

      # TODO: Restrict /admin to trusted networks only.
      # Langport (DMZ) can reach messeldam directly, so messeldam needs its
      # own L7 filtering — langport's nginx blocks alone are insufficient
      # if langport is compromised.
      locations."/" = {
        proxyPass = "http://127.0.0.1:9080";
        extraConfig = proxyConfig;
      };
    };
  };

  # Bootstrap: issue the initial TLS certificate if it doesn't exist yet.
  # On first boot, step-ca must be reachable. On subsequent boots, the cert
  # is already on disk and nginx starts immediately.
  systemd.services.step-tls-bootstrap = {
    description = "Bootstrap TLS certificate from step-ca";
    wantedBy = ["nginx.service"];
    before = ["nginx.service"];
    unitConfig.ConditionPathExists = "!${certFile}";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
      RestartMaxDelaySec = 300;
      RestartSteps = 5;
    };
    script = ''
      mkdir -p ${certDir}
      chown root:nginx ${certDir}
      chmod 750 ${certDir}
      ${pkgs.step-cli}/bin/step ca certificate \
        ${certDomain} ${certFile} ${keyFile} \
        --ca-url ${caUrl} \
        --root ${caRoot} \
        --provisioner acme \
        --force
      chmod 640 ${keyFile}
      chown root:nginx ${keyFile}
    '';
  };

  # Renewal timer: renew the cert when less than 15 days remain.
  # step ca renew exits 0 and does nothing if the cert isn't due for renewal.
  systemd.services.step-tls-renew = {
    description = "Renew TLS certificate from step-ca";
    unitConfig.ConditionPathExists = certFile;
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      ${pkgs.step-cli}/bin/step ca renew \
        ${certFile} ${keyFile} \
        --ca-url ${caUrl} \
        --root ${caRoot} \
        --expires-in 360h \
        --force \
        && ${pkgs.systemd}/bin/systemctl reload nginx
    '';
  };

  systemd.timers.step-tls-renew = {
    description = "Daily TLS certificate renewal check";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
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
        directory = "/var/lib/step-tls";
        mode = "0750";
        group = "nginx";
      }
      {
        directory = "/var/lib/postgresql";
        user = "postgres";
        group = "postgres";
      }
    ];
  };
}
