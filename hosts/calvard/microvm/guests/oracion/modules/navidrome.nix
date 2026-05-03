{config, ...}: let
  vhost = "navidrome.internal";
in {
  services.navidrome = {
    enable = true;
    settings = {
      Address = "127.0.0.1";
      Port = 4533;
      MusicFolder = "/media/library/music";
    };
  };

  security.acme.certs."${vhost}".group = "acme-cert";

  services.nginx.virtualHosts."${vhost}" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:4533";
      extraConfig = ''
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/navidrome";
      user = config.users.users.navidrome.name;
      inherit (config.users.users.navidrome) group;
    }
  ];
}
