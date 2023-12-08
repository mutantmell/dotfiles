{ config, ... }: {
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
    secrets = {
      "wpa.env" = {};
      "zwavejs.secrets" = {
        mode = "0444";
      };
    };
  };
}
