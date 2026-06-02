{config, ...}: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    # TODO: Re-enable after messeldam (Keycloak) + basel (step-ca) are deployed
    # secrets = {
    #   "oauth2-proxy-internal-keyfile" = {};
    # };
  };
}
