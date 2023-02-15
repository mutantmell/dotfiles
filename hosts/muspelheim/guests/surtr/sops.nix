{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
    secrets = {
      "wireguard_private_key" = {};
      "wireguard_peer_address" = {};
    };
  };
}
