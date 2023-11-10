{
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml; # todo: populate once we have a host key defined
    # use host keys by default
    secrets = {
      "wireguard_private_key" = {};
      "wg_ba_peer_1_address" = {};
      "wg_ba_peer_2_address" = {};
      "oauth-2-proxy-keyfile" = {};
    };
  };
}
