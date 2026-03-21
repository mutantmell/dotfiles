_: {
  networking.firewall.allowedTCPPorts = [2586];

  services.ntfy-sh = {
    enable = true;
    settings = {
      listen-http = ":2586";
      base-url = "http://tharbad.internal:2586";
    };
  };

  environment.persistence."/persist".directories = [
    "/var/lib/private/ntfy-sh"
  ];
}
