{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    secrets = {
      "wireguard_private_key" = {};
      "wg_ba_peer_1_address" = {};
      "wg_ba_peer_2_address" = {};
      "oauth-2-proxy-keyfile" = {};
    };
  };
}
