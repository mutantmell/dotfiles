{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      "attic.env" = {};
    };
  };
}
