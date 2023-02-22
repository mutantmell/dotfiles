{ config, ... }:
{
  config = {
    networking.firewall.allowedTCPPorts = [ 80 443 4180 ]; # 4180 is temporary
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
          extraConfig = ''
            auth_request /oauth2/auth;
            error_page 401 = /oauth2/sign_in;

            # pass information via X-User and X-Email headers to backend,
            # requires running with --set-xauthrequest flag
            auth_request_set $user   $upstream_http_x_auth_request_user;
            auth_request_set $email  $upstream_http_x_auth_request_email;
            proxy_set_header X-User  $user;
            proxy_set_header X-Email $email;

            # if you enabled --pass-access-token, this will pass the token to the backend
            auth_request_set $token  $upstream_http_x_auth_request_access_token;
            proxy_set_header X-Access-Token $token;

            # if you enabled --cookie-refresh, this is needed for it to work with auth_request
            auth_request_set $auth_cookie $upstream_http_set_cookie;
            add_header Set-Cookie $auth_cookie;

            # When using the --set-authorization-header flag, some provider's cookies can exceed the 4kb
            # limit and so the OAuth2 Proxy splits these into multiple parts.
            # Nginx normally only copies the first `Set-Cookie` header from the auth_request to the response,
            # so if your cookies are larger than 4kb, you will need to extract additional cookies manually.
            auth_request_set $auth_cookie_name_upstream_1 $upstream_cookie_auth_cookie_name_1;

            # Extract the Cookie attributes from the first Set-Cookie header and append them
            # to the second part ($upstream_cookie_* variables only contain the raw cookie content)
            if ($auth_cookie ~* "(; .*)") {
                set $auth_cookie_name_0 $auth_cookie;
                set $auth_cookie_name_1 "auth_cookie_name_1=$auth_cookie_name_upstream_1$1";
            }

            # Send both Set-Cookie headers now if there was a second part
            if ($auth_cookie_name_upstream_1) {
                add_header Set-Cookie $auth_cookie_name_0;
                add_header Set-Cookie $auth_cookie_name_1;
            }
            proxy_pass https://bragi;
          '';
        };

        locations."/oauth2/" = {
          proxyPass = "http://127.0.0.1:4180";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Scheme $scheme;
            proxy_set_header X-Auth-Request-Redirect $request_uri;
          '';
        };
        locations."/oauth2/auth" = {
          proxyPass = "http://127.0.0.1:4180";
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Scheme $scheme;
            proxy_set_header Content-Length   "";
            proxy_pass_request_body           off;
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
