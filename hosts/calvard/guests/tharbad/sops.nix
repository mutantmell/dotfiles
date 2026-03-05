{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/static/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      "grafana-admin-password" = {};
      "alertmanager-ntfy-url" = {};
      "ntfy-auth-token" = {};
    };
  };
}
