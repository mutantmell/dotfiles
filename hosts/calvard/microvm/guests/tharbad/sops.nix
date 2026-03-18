{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "grafana-admin-password" = {};
      "grafana-secret-key" = {};
      # TODO: add to secrets.yaml when ntfy auth is configured
      # "alertmanager-ntfy-url" = {};
      # "ntfy-auth-token" = {};
    };
  };
}
