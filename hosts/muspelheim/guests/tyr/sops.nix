{ config, ... }:

{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/static/etc/ssh/ssh_host_ed25519_key" ];
    secrets = let
      step-ca = {
        mode = "0400";
        owner = config.users.users."step-ca".name;
        group = config.users.users."step-ca".group;
      };
    in {
      "intermediate_ca.key" = step-ca;
      "intermediate-password-file" = step-ca;
    };
  };
}
