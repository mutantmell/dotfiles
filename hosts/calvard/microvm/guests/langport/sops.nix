{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      "oauth-2-proxy-keyfile" = {};
    };
  };
}
