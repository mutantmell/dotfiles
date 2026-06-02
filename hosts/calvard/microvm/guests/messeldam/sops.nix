{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = {
      "keycloak_password_file" = {};
      "keycloak_admin_password" = {};
    };
  };
}
