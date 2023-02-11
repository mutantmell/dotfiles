{ config, pkgs, ... }:

{
  networking.firewall = {
    allowedUDPPorts = [ 51820 ];
  };

  networking.wireguard.interfaces = {
    wg0 = let
      addr = octlet: "10.100.0.${octlet}";
    in {
      ips = [ (addr "2/24") ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard-key.path;

      peers = [
        {
          publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
          allowedIPs = [ (addr "1/32") ];
          endpoint = "helveticastandard.com:51820"; # todo: route to endpoint not automatically configured https://wiki.archlinux.org/index.php/WireGuard#Loop_routing https://discourse.nixos.org/t/solved-minimal-firewall-setup-for-wireguard-client/7577
          persistentKeepalive = 25;
        }
      ];
    };
  };
}
