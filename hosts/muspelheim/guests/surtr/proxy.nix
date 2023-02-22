{ config, ... }:
{
  config = {
    networking.firewall.allowedTCPPorts = [ 443 4180 ]; # 4180 is temporary
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
          proxyPass = "http://127.0.0.1:4180";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Scheme $scheme;
            proxy_set_header X-Auth-Request-Redirect $request_uri;
          '';
        };
      };
    };
    services.oauth2_proxy = {
      enable = true;
      keyFile = config.sops.secrets."oauth-2-proxy-keyfile".path;
      provider = "oidc";
      clientID = "oauth2-proxy";
      upstream = [
        "https://bragi.local"
      ];
      redirectURL = "http://surtr.local:4180/oauth2/callback";
      reverseProxy = true;
      email.domains = ["*"];
      httpAddress = ":4180";
      scope = "openid profile email";
      cookie.domain = ".surtr.local";  # todo change
      cookie.refresh = "1m";
      cookie.expire = "30m";
      cookie.secure = false;

      setXauthrequest = true;
      passAccessToken = true;
      
      extraConfig = {
        "provider-display-name" = "Keycloak";
        "oidc-issuer-url" = "https://alfheim.local/auth/realms/external";
        #"code-challenge-method" = "S256";
        "pass-authorization-header" = true;
        "pass-user-headers" = true;
        "set-authorization-header" = true;

        "cookie-csrf-per-request" = true;
        "cookie-csrf-expire" = "5m";
      };
    };
  };
}
