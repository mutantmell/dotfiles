{ config, ... }:
{
  config = {
    networking.wireguard.interfaces = {
      "wg0" = {
        ips = [ "10.100.0.1/24" ];
        privateKeyFile = config.sops.secrets."wireguard_private_key".path;
        peers = [
          {
            publicKey = "QdA39mQUqQjSvOTy4c+Zrtll1OEb/4vroewi2Zz6+Qs=";
            allowedIPs = [ "10.100.0.0/24" ];
            endpointFile = config.sops.secrets."wireguard_peer_address".path;
            dynamicEndpointRefreshSeconds = 15;
            persistentKeepalive = 25;
          }
        ];
      };
      "wg-mx" = {
        ips = [ "10.100.1.2/32" ];
        privateKeyFile = config.sops.secrets."wireguard_private_key".path;
        peers = [
          {
            publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
            allowedIPs = [ "10.100.1.0/24" ];
            endpoint = "helveticastandard.com:51895";
            persistentKeepalive = 25;
          }
        ];
      };
    };
  };
}
