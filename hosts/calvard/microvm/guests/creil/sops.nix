{config, ...}: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = ["/static/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "forgejo-admin-password" = {
        mode = "0400";
        owner = config.users.users.forgejo.name;
        inherit (config.users.users.forgejo) group;
      };
    };
  };
}
