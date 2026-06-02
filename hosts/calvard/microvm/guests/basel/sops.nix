{config, ...}: {
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.keyFile = "/static/var/lib/sops-nix/key.txt";
    secrets = let
      step-ca = {
        mode = "0400";
        owner = config.users.users."step-ca".name;
        inherit (config.users.users."step-ca") group;
      };
    in {
      "intermediate_ca.key" = step-ca;
      "intermediate-password-file" = step-ca;
      "ssh_user_ca_key" = step-ca;
      "ssh_host_ca_key" = step-ca;
    };
  };
}
