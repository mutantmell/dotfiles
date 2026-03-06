{ config, ...}:
{
  services.atticd = {
    enable = true;
    environmentFile = config.sops.secrets."attic.env".path;
    settings = {
      listen = "[::]:8080";
      chunking = {
        nar-size-threshold = 64 * 1024;
        min-size = 16 * 1024;
        avg-size = 64 * 1024;
        max-size = 256 * 1024;
      };
      garbage-collection = {
        retention-period = "3m";
      };
    };
  };

  environment.persistence."/persist" = {
    directories = [
      { directory = "/var/lib/private/atticd"; user = "atticd"; group = "atticd"; }
    ];
  };

  services.nginx.virtualHosts."attic.ardent.internal" = {
    forceSSL = true;
    enableACME = true;

    locations."/" = {
      proxyPass = "http://[::1]:8080";
      proxyWebsockets = true;
      extraConfig = ''
        client_max_body_size 512M;
      '';
    };
  };
}
