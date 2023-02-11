{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
    secrets = {
      wireguard-key = {};
      synapse-compress-env = {};
      pgpass = {
        path = "/root/.pgpass";
      };
    };
  };
}
