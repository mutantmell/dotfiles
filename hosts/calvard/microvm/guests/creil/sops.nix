{config, ...}: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
      "forgejo-admin-password" = {
        mode = "0400";
        owner = config.users.users.forgejo.name;
        inherit (config.users.users.forgejo) group;
      };
    };
  };
}
