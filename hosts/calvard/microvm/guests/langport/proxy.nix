{config, ...}: {
  config = {
    networking.firewall.allowedTCPPorts = [80 443];
    environment.persistence."/persist".directories = [
      {
        directory = "/var/lib/acme";
        user = "acme";
        group = "acme";
      }
    ];
    security.acme = {
      defaults = {
        server = "https://basel.internal/acme/acme/directory";
        email = "malaguy@gmail.com";
      };
      acceptTerms = true;
    };
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      # Rate limiting for auth endpoints (S11)
      commonHttpConfig = ''
        limit_req_zone $binary_remote_addr zone=auth_limit:10m rate=10r/s;
        limit_req_zone $binary_remote_addr zone=oauth2_limit:10m rate=10r/s;
      '';

      virtualHosts."mutantmell.net" = let
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
          proxyPass = "https://oracion.internal";
          extraConfig = jellyfinConf;
        };
      };

      virtualHosts."auth.mutantmell.net" = {
        forceSSL = true;
        enableACME = true;

        # Block admin console access from external users (S5)
        locations."/auth/admin" = {
          return = "403";
        };
        locations."/auth/realms/master" = {
          return = "403";
        };

        locations."/auth" = {
          proxyPass = "https://messeldam.internal/auth";
          extraConfig = ''
            proxy_set_header X-Forwarded-For $remote_addr;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Host $host;

            proxy_buffer_size   128k;
            proxy_buffers   4 256k;
            proxy_busy_buffers_size   256k;

            limit_req zone=auth_limit burst=20 nodelay;
          '';
        };
      };
    };
    services.oauth2-proxy = {
      enable = true;
      nginx = {
        proxy = "http://127.0.0.1:4180";
        virtualHosts = {
          "mutantmell.net" = {};
        };
        domain = ".mutantmell.net";
      };
      keyFile = config.sops.secrets."oauth-2-proxy-keyfile".path;
      provider = "oidc";
      clientID = "oauth2-proxy";
      upstream = [
        "https://oracion.internal"
      ];
      redirectURL = "https://mutantmell.net/oauth2/callback";
      email.domains = ["*"];
      httpAddress = ":4180";
      cookie.refresh = "1m";
      cookie.expire = "30m";
      cookie.secure = true;

      setXauthrequest = true;

      extraConfig = {
        "provider-display-name" = "Keycloak";
        "oidc-issuer-url" = "https://auth.mutantmell.net/auth/realms/homelab";
      };
    };
  };
}
