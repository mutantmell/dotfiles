{
  config,
  lib,
  ...
}: let
  cfg = config.services.forgejo;
  exe = lib.getExe cfg.package;
in {
  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    settings = {
      DEFAULT.APP_NAME = "Forgejo";
      server = {
        DOMAIN = "forgejo.internal";
        ROOT_URL = "https://forgejo.internal/";
        HTTP_PORT = 3000;
        HTTP_ADDR = "127.0.0.1";
        SSH_DOMAIN = "forgejo.internal";
        SSH_PORT = 22;
      };
      service = {
        DISABLE_REGISTRATION = true;
        REQUIRE_SIGNIN_VIEW = false;
      };
      packages.ENABLED = true;
      mirror.ENABLED = true;
      session.COOKIE_SECURE = true;
      webhook.ALLOWED_HOST_LIST = "external,woodpecker.internal";
    };
  };

  services.caddy.virtualHosts = let
    forgejoVhost.extraConfig = ''
      # Keep the web/git upload cap while allowing large OCI registry layers.
      @bounded not path /v2/*
      request_body @bounded {
        max_size 512MiB
      }
      # Caddy streams requests and supports WebSockets by default.
      reverse_proxy 127.0.0.1:3000
    '';
  in {
    "creil.internal" = forgejoVhost;
    "forgejo.internal" = forgejoVhost;
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
      WorkingDirectory = cfg.stateDir;
      RemainAfterExit = true;
    };
    environment = {
      FORGEJO_WORK_DIR = cfg.stateDir;
      FORGEJO_CUSTOM = cfg.customDir;
    };
    script = let
      forgejo = "${exe} --config ${cfg.customDir}/conf/app.ini";
    in ''
      PASSWORD=$(cat ${config.sops.secrets."forgejo-admin-password".path})
      # Create admin user if it doesn't exist; update password if it does
      ${forgejo} admin user create \
        --username forgejo-admin \
        --email forgejo-admin@creil.internal \
        --password "$PASSWORD" \
        --admin \
        --must-change-password=false 2>&1 || \
      ${forgejo} admin user change-password \
        --username forgejo-admin \
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
