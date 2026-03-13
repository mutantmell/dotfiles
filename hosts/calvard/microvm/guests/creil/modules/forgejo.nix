{
  config,
  lib,
  ...
}: let
  exe = lib.getExe config.services.forgejo.package;
in {
  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    settings = {
      DEFAULT.APP_NAME = "Forgejo";
      server = {
        DOMAIN = "creil.internal";
        ROOT_URL = "https://creil.internal/";
        HTTP_PORT = 3000;
        HTTP_ADDR = "127.0.0.1";
        SSH_DOMAIN = "creil.internal";
        SSH_PORT = 2222;
        START_SSH_SERVER = true;
      };
      service = {
        DISABLE_REGISTRATION = true;
        REQUIRE_SIGNIN_VIEW = false;
      };
      packages.ENABLED = true;
      mirror.ENABLED = true;
      session.COOKIE_SECURE = true;
    };
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    virtualHosts."creil.internal" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
      };
    };
  };

  systemd.services.forgejo-admin = {
    description = "Ensure Forgejo admin user exists";
    after = ["forgejo.service"];
    requires = ["forgejo.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      User = "forgejo";
      Group = "forgejo";
      WorkingDirectory = config.services.forgejo.stateDir;
      RemainAfterExit = true;
    };
    script = ''
      PASSWORD=$(cat ${config.sops.secrets."forgejo-admin-password".path})
      # Create admin user if it doesn't exist; update password if it does
      ${exe} admin user create \
        --username admin \
        --email admin@creil.internal \
        --password "$PASSWORD" \
        --admin \
        --must-change-password=false 2>&1 || \
      ${exe} admin user change-password \
        --username admin \
        --password "$PASSWORD"
    '';
  };

  environment.persistence."/persist" = {
    directories = [
      {
        directory = "/var/lib/forgejo";
        user = "forgejo";
        group = "forgejo";
      }
    ];
  };
}
