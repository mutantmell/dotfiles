{ config, ... }:
{
  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.blog = {
    image = "ardent.internal/admin/blog:latest";
    ports = [ "127.0.0.1:8081:80" ];
    extraOptions = [ "--pull=always" ];
  };

  virtualisation.oci-containers.containers.homepage = {
    image = "ardent.internal/admin/homepage:latest";
    ports = [ "127.0.0.1:8082:3000" ];
    extraOptions = [ "--pull=always" ];
  };

  services.nginx.virtualHosts."blog.ardent.internal" = {
    forceSSL = true;
    enableACME = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:8081";
    };
  };

  services.nginx.virtualHosts."home.ardent.internal" = {
    forceSSL = true;
    enableACME = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:8082";
      proxyWebsockets = true;
    };
  };
}
