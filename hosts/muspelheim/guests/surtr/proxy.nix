{ config, ... }:
{
  config = {
    services.oauth2_proxy = {
      enable = true;
      keyFile = config.sops.secrets."oauth-2-proxy-keyfile".path;
      provider = "keycloak-oidc";
      clientID = "oauth2-proxy";
      upstream = [
        "https://bragi.local"
      ];
      redirectURL = "http://10.100.1.1/oauth2/callback";
      email.domains = ["*"];
      extraConfig = {
        "oidc-issuer-url" = "https://alfheim.local/auth/realms/external";
        "code-challenge-method" = "S256";
      };
    };
  };
}
