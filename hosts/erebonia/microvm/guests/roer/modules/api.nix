{
  config,
  pkgs,
  lib,
  ...
}: let
  certDomain = "roer.internal";
  certDir = "/var/lib/step-tls/${certDomain}";
  certFile = "${certDir}/cert.pem";
  keyFile = "${certDir}/key.pem";
  caUrl = "https://basel.internal";
  caRoot = "/etc/ssl/certs/ca-certificates.crt";
  deployUid = pkgs.mmell.lib.data.deployd.uid;
in {
  # Static UID — pinned for consistency with deployd-helper UID on erebonia.
  # Originally required for virtiofs UID mapping; retained for stability.
  users.users.deployd-api = {
    isSystemUser = true;
    uid = deployUid;
    group = "deployd-api";
    description = "deployd API service";
  };
  users.groups.deployd-api.gid = deployUid;

  sops.secrets."deployd-capability-token".owner = "deployd-api";

  # deployd-api systemd service
  systemd.services.deployd-api = {
    description = "deployd container deployment API";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "nginx.service"];
    wants = ["network-online.target"];

    environment = {
      DEPLOYD_HELPER_VSOCK_PORT = "7000";
      DEPLOYD_CAPABILITY_TOKEN_FILE = config.sops.secrets."deployd-capability-token".path;
      DEPLOYD_OIDC_ISSUER = "https://auth.mutantmell.net/realms/homelab";
      DEPLOYD_REQUIRED_GROUP = "deploy";
    };

    serviceConfig.ExecStart = "${pkgs.mmell.deployd-api}/bin/deployd-api";

    serviceConfig = {
      User = "deployd-api";
      Group = "deployd-api";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6" "AF_VSOCK"];
      RestrictNamespaces = true;
      SystemCallFilter = ["@system-service" "~@privileged"];
    };
  };

  # Nginx reverse proxy: TLS termination → deployd-api (localhost:8443)
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;

    virtualHosts.${certDomain} = {
      forceSSL = true;
      sslCertificate = certFile;
      sslCertificateKey = keyFile;

      locations."/" = {
        proxyPass = "http://127.0.0.1:8443";
      };
    };
  };

  # Bootstrap: issue the initial TLS certificate if it doesn't exist yet.
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
      ${pkgs.step-cli}/bin/step ca certificate \
        ${certDomain} ${certFile} ${keyFile} \
        --ca-url ${caUrl} \
        --root ${caRoot} \
        --provisioner acme \
        --force
      chmod 644 ${certFile}
      chmod 640 ${keyFile}
      chown root:nginx ${certFile} ${keyFile}
    '';
  };

  # Renewal timer: renew the cert when less than 15 days remain.
  systemd.services.step-tls-renew = {
    description = "Renew TLS certificate from step-ca";
    unitConfig.ConditionPathExists = certFile;
    serviceConfig.Type = "oneshot";
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

  # Ensure cert directories exist with correct ownership before services start.
  systemd.tmpfiles.rules = [
    "d /var/lib/step-tls 0750 root nginx -"
    "d ${certDir} 0750 root nginx -"
  ];

  environment.persistence."/persist" = {
    directories = [
      {
        directory = "/var/lib/step-tls";
        mode = "0750";
        group = "nginx";
      }
    ];
  };
}
