{
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/persist/var/lib/sops-nix/key.txt";
    secrets = {
      "deployd-capability-token".owner = "deployd-helper";
    };
  };
}
