{ config, ... }:
{
  config = {
    networking.wireguard.interfaces = {
      "wg-ba" = {
        ips = [ "10.100.0.1/32" ];
        privateKeyFile = config.sops.secrets."wireguard_private_key".path;
        peers = [
          {
            publicKey = "QdA39mQUqQjSvOTy4c+Zrtll1OEb/4vroewi2Zz6+Qs=";
            allowedIPs = [ "10.100.0.2/32" ];
            endpointFile = config.sops.secrets."wg_ba_peer_1_address".path;
            dynamicEndpointRefreshSeconds = 15;
            persistentKeepalive = 25;
          }
          {
            publicKey = "O+WWPlhy6Lg9YT3hYqq+/8gZ48PpRXaUTl4eFFwgTVA=";
            allowedIPs = [ "10.100.0.3/32" ];
            endpointFile = config.sops.secrets."wg_ba_peer_2_address".path;
            dynamicEndpointRefreshSeconds = 15;
            persistentKeepalive = 25;
          }
        ];
      };
      # "wg-mx" = {
      #   ips = [ "10.100.1.2/32" ];
      #   privateKeyFile = config.sops.secrets."wireguard_private_key".path;
      #   peers = [
      #     {
      #       publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
      #       allowedIPs = [ "10.100.1.0/24" ];
      #       endpoint = "helveticastandard.com:51895";
      #       persistentKeepalive = 25;
      #     }
      #   ];
      # };
    };
  };
}
