{ config, ... }:

{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
    secrets = let
      step-ca = {
        mode = "0400";
        owner = config.users.users."step-ca".name;
        group = config.users.users."step-ca".group;
      };
    in {
      "intermediate_ca.key" = step-ca;
      "intermediate-password-file" = step-ca;
      "keycloak_password_file" = step-ca;
    };
  };
}
