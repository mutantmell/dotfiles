{ ... }:
{
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

  environment.persistence."/persist" = {
    directories = [
      { directory = "/var/lib/forgejo"; user = "forgejo"; group = "forgejo"; }
    ];
  };
}
