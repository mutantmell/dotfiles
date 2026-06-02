_: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
      "perses-oidc-client-secret" = {};
      "perses-encryption-key" = {};
      "ntfy-admin-password" = {};
    };
  };
}
