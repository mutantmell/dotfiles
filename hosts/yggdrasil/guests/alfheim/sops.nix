{ config, ... }:

{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/static/etc/ssh/ssh_host_ed25519_key" ];
    # TODO: Re-enable after mimir (Keycloak) + tyr (step-ca) are deployed
    # secrets = {
    #   "oauth2-proxy-internal-keyfile" = {};
    # };
  };
}
