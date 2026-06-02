{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
      "oauth-2-proxy-keyfile" = {};
    };
  };
}
