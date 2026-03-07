_: {
  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    settings = {
      DEFAULT.APP_NAME = "Forgejo";
      server = {
        DOMAIN = "git.internal";
        ROOT_URL = "https://git.internal/";
        HTTP_PORT = 3000;
        HTTP_ADDR = "0.0.0.0";
        SSH_DOMAIN = "ardent.internal";
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

  networking.firewall.allowedTCPPorts = [3000 2222];

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
