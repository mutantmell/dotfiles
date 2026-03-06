{ config, ... }:
{
  networking.firewall.allowedTCPPorts = [ 2586 ];

  services.ntfy-sh = {
    enable = true;
    settings = {
      listen-http = ":2586";
      base-url = "http://ymir.internal:2586";
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/ntfy-sh";
      user = "ntfy-sh";
      group = "ntfy-sh";
    }
  ];
}
