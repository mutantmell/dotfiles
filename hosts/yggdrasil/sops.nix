{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
    secrets = {
      "chap-secrets" = {
        path = "/etc/ppp/chap-secrets";
      };
      "pppd-userfile" = {};
    };
  };
}
