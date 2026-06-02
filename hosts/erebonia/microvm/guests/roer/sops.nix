{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
      "deployd-capability-token" = {};
    };
  };
}
