{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
    secrets = {
      "intermediate_ca.key" = {};
      "intermediate-password-file" = {};
      "keycloak_password_file" = {};
    };
  };
}
