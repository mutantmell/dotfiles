{ config, pkgs, ... }:

# OAuth-protected reverse proxy for Adguard Home web UI
# Uses a local oauth2-proxy instance that authenticates directly against Keycloak (on mimir)
#
# Flow:
# 1. User accesses https://alfheim.local/adguard/
# 2. Nginx makes auth_request to local oauth2-proxy
# 3. If not authenticated, oauth2-proxy redirects to Keycloak (on mimir)
# 4. After successful OAuth, user is redirected back
# 5. Nginx proxies authenticated requests to local Adguard Home

{
  networking.firewall.allowedTCPPorts = [
    80    # HTTP (redirects to HTTPS)
    443   # HTTPS
  ];

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;

    virtualHosts."${config.networking.hostName}.local" = {
      forceSSL = true;
      enableACME = true;

      # OAuth2 authentication endpoints - proxy to local oauth2-proxy
      locations."/oauth2/" = {
        proxyPass = "http://127.0.0.1:4180/oauth2/";
        extraConfig = ''
          proxy_set_header Host                    $host;
          proxy_set_header X-Real-IP               $remote_addr;
          proxy_set_header X-Scheme                $scheme;
          proxy_set_header X-Auth-Request-Redirect $request_uri;
        '';
      };

      # Internal auth_request endpoint
      locations."= /oauth2/auth" = {
        proxyPass = "http://127.0.0.1:4180/oauth2/auth";
        extraConfig = ''
          proxy_set_header Host             $host;
          proxy_set_header X-Real-IP        $remote_addr;
          proxy_set_header X-Scheme         $scheme;
          proxy_set_header Content-Length   "";
          proxy_pass_request_body           off;

          # Cache auth responses briefly to reduce load
          proxy_cache_valid 200 1m;
        '';
      };

      # Adguard Home web UI - OAuth protected
      locations."/adguard" = {
        return = "302 /adguard/";
      };

      locations."/adguard/" = {
        proxyPass = "http://127.0.0.1:3000/";
        proxyWebsockets = true;
        extraConfig = ''
          # Require OAuth authentication
          auth_request /oauth2/auth;
          error_page 401 = /oauth2/sign_in;

          # Pass auth info to upstream
          auth_request_set $user   $upstream_http_x_auth_request_user;
          auth_request_set $email  $upstream_http_x_auth_request_email;
          proxy_set_header X-User  $user;
          proxy_set_header X-Email $email;

          # Pass original request info
          auth_request_set $auth_cookie $upstream_http_set_cookie;
          add_header Set-Cookie $auth_cookie;

          # Standard proxy headers
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };

      # Root redirect to Adguard
      locations."/" = {
        return = "302 /adguard/";
      };
    };
  };

  services.oauth2-proxy = {
    enable = true;
    keyFile = config.sops.secrets."oauth2-proxy-internal-keyfile".path;
    provider = "oidc";
    clientID = "oauth2-proxy-internal";
    redirectURL = "https://alfheim.local/oauth2/callback";
    email.domains = ["*"];
    httpAddress = "127.0.0.1:4180";
    cookie.refresh = "1m";
    cookie.expire = "30m";
    cookie.secure = true;
    setXauthrequest = true;
    extraConfig = {
      "provider-display-name" = "Keycloak";
      "oidc-issuer-url" = "https://mimir.local/auth/realms/external";
    };
  };

  # ACME certificate configuration - get certs from tyr's Step CA
  security.acme = {
    defaults = {
      server = "https://tyr.local/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
  };
}
