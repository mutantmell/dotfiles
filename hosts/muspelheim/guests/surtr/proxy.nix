{ config, ... }:
{
  config = {
    networking.firewall.allowedTCPPorts = [ 80 443 4180 ]; # 4180 is temporary
    networking.nat = {
      enable = true;
      externalInterface = "wg-mx";
      internalInterfaces = [ "ens3" ];
      internalIPs = [ "10.0.100.0/24" ];
    };
    security.acme = {
      defaults = {
        server = "https://alfheim.local/acme/acme/directory";
        email = "malaguy@gmail.com";
      };
      acceptTerms = true;
    };
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      virtualHosts."${config.networking.hostName}.local" = {
        forceSSL = true;
        enableACME = true;
        extraConfig = ''
          proxy_buffer_size   128k;
          proxy_buffers   4 256k;
          proxy_busy_buffers_size   256k;
        '';

        locations."/" = {
          proxyPass = "https://bragi.local";
        };
      };
    };
    services.oauth2_proxy = {
      enable = true;
      nginx = {
        proxy = "http://127.0.0.1:4180";
        virtualHosts = [
          "${config.networking.hostName}.local"
        ];
      };
      keyFile = config.sops.secrets."oauth-2-proxy-keyfile".path;
      provider = "oidc";
      clientID = "oauth2-proxy";
      upstream = [
        "https://bragi.local"
      ];
      redirectURL = "http://surtr.local:4180/oauth2/callback";
      email.domains = ["*"];
      httpAddress = ":4180";
      #cookie.domain = ".surtr.local";  # todo change
      cookie.refresh = "1m";
      cookie.expire = "30m";
      cookie.secure = false;

      setXauthrequest = true;
      passAccessToken = true;
      
      extraConfig = {
        "provider-display-name" = "Keycloak";
        "oidc-issuer-url" = "https://alfheim.local/auth/realms/external";
        "set-authorization-header" = true;
      };
    };
  };
}
