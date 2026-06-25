{config, ...}: {
  services.woodpecker-server = {
    enable = true;
    environment = {
      WOODPECKER_HOST = "https://woodpecker.internal";
      WOODPECKER_SERVER_ADDR = "127.0.0.1:8000";
      WOODPECKER_GRPC_ADDR = ":9000";
      WOODPECKER_ADMIN = "mutantmell";
      WOODPECKER_OPEN = "true";
      WOODPECKER_REPO_OWNERS = "mutantmell";
      WOODPECKER_FORGEJO = "true";
      WOODPECKER_FORGEJO_URL = "https://forgejo.internal";
      WOODPECKER_DEFAULT_CLONE_PLUGIN = "localhost/woodpecker-plugin-git:2.9.1-internal-ca";
      WOODPECKER_PLUGINS_TRUSTED_CLONE = "localhost/woodpecker-plugin-git:2.9.1-internal-ca,plugin-git";
    };
    environmentFile = [config.sops.templates."woodpecker-server.env".path];
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    virtualHosts."woodpecker.internal" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8000";
        proxyWebsockets = true;
      };
    };
  };
}
