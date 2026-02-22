{ config, ... }: {
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      "wpa.env" = {};
      "zwavejs.secrets" = {
        mode = "0444";
      };
    };
  };
}
