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

      virtualHosts."${config.networking.hostName}.local" = let
        jellyfinConf = ''
          add_header X-Frame-Options "SAMEORIGIN";
          add_header X-XSS-Protection "1; mode=block";
          add_header X-Content-Type-Options "nosniff";

          add_header Strict-Transport-Security "max-age=31536000" always;

          # Content Security Policy
          # See: https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP
          # Enforces https content and restricts JS/CSS to origin
          # External Javascript (such as cast_sender.js for Chromecast or YouTube embed JS for external trailers) must be whitelisted.
          add_header Content-Security-Policy "default-src https: data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' https://www.gstatic.com/cv/js/sender/v1/cast_sender.js https://www.youtube.com/iframe_api https://s.ytimg.com; worker-src 'self' blob:; connect-src 'self'; object-src 'none'; frame-ancestors 'self'";
      '';
      in {
        forceSSL = true;
        enableACME = true;

        extraConfig = ''
          proxy_read_timeout 604800;
          proxy_send_timeout 604800;
          proxy_buffer_size   128k;
          proxy_buffers   4 256k;
          proxy_busy_buffers_size   256k;
        '';
        locations."/" = {
          proxyPass = "https://bragi.local";
          extraConfig = jellyfinConf;
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
      redirectURL = "http://surtr.local/oauth2/callback";
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
        "skip-jwt-bearer-tokens" = true;
      };
    };
  };
}
