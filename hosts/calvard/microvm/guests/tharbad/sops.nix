{config, ...}: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "grafana-admin-password" = {
        mode = "0400";
        owner = config.users.users.grafana.name;
      };
      "grafana-secret-key" = {
        mode = "0400";
        owner = config.users.users.grafana.name;
      };
      "grafana-oidc-client-secret" = {
        mode = "0400";
        owner = config.users.users.grafana.name;
      };
      # TODO: add to secrets.yaml when ntfy auth is configured
      # "alertmanager-ntfy-url" = {};
      # "ntfy-auth-token" = {};
    };
  };
}
