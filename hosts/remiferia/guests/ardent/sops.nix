{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      "attic.env" = {};
      "forgejo-runner-token" = {};
    };
  };
}
