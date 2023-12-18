{ config, pkgs, ... }:

{
  services.unifi = {
    enable = true;
    openFirewall = true;
    unifiPackage = pkgs.unifi8;
    maximumJavaHeapSize = 256;
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."unifi.${config.networking.hostName}.local" = {
      locations."/" = {
        proxyPass = "http://localhost:8443";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 8443 ];

  environment.persistence."/persist" = {
    directories = [
      { directory = "/var/lib/unifi"; user = "unifi"; group = "unifi"; }
    ];
  };
}
