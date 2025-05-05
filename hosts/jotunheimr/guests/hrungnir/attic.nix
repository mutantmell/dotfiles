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

  # TODO: nginx site "attic.hrungnir.local"
}
