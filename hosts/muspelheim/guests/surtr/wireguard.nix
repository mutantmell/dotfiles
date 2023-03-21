{ pkgs, config, ... }:
{
  config = {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    networking.nat = {
      enable = true;
      externalInterface = "wg-ba";
      internalInterfaces = [ "ens3" ];
    };

    networking.firewall.interfaces = let
      non-mx-ports = {
        allowedTCPPorts = [ 22 ];
      };
    in {
      "wg-ba" = non-mx-ports;
      "ens3" = non-mx-ports;
    };
    networking.wireguard.interfaces = {
      "wg-ba" = {
        ips = [ "10.100.0.1/32" ];
        listenPort = 38506;
        privateKeyFile = config.sops.secrets."wireguard_private_key".path;

        postSetup = ''
          ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o wg-ba -j MASQUERADE
        '';
        postShutdown = ''
          ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.100.0.0/24 -o wg-ba -j MASQUERADE
        '';

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
      "wg-mx" = {
        ips = [ "10.100.1.2/32" ];
        privateKeyFile = config.sops.secrets."wireguard_private_key".path;

        postSetup = ''
          ${pkgs.iproute}/bin/ip route add 10.100.1.1 dev wg-mx
        '';
        postShutdown = ''
          ${pkgs.iproute}/bin/ip route del 10.100.1.1 dev wg-mx
        '';

        peers = [
          {
            publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
            allowedIPs = [ "10.100.1.1/32" ];
            endpoint = "helveticastandard.com:58156";
            persistentKeepalive = 25;
          }
        ];
      };
    };
  };
}
