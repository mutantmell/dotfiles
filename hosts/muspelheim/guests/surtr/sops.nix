{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = [ "/root/.ssh/id_ed25519" ];
    secrets = {
      "wireguard_private_key" = {};
      "wg_ba_peer_1_address" = {};
      "wg_ba_peer_2_address" = {};
      "oauth-2-proxy-keyfile" = {};
    };
  };
}
