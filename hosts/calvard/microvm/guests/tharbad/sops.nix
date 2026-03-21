_: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "perses-oidc-client-secret" = {};
      "perses-encryption-key" = {};
      "ntfy-admin-password" = {};
    };
  };
}
