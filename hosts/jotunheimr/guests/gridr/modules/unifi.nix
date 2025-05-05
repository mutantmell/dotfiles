{ config, pkgs, ... }:

{
  services.unifi = {
    enable = true;
    openFirewall = true;
    unifiPackage = pkgs.unifi8;
    mongodbPackage = pkgs.mongodb-7_0;
    maximumJavaHeapSize = 256;
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."unifi.${config.networking.hostName}.local" = {
      locations."/" = {
        proxyPass = "https://localhost:8443";
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
