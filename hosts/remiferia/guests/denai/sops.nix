{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      smb-credentials = {};
    };
  };
}
