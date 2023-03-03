{ config, pkgs, ...}:

{

  networking.firewall = {
    allowedUDPPorts = [ 58156 ];
  };

  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ "10.100.1.1/24" ];
      listenPort = 58156;
      privateKeyFile = config.sops.secrets.wireguard-key.path;

      peers = [
        {
          publicKey = "6Kb9OxV5mmCDt8GNTYTQi745sXI/ON7R9ZKnhuXPKiA=";
          allowedIPs = [ "10.100.1.2/32" "10.0.0.0/16" ];
        }
      ];
    };
  };
}
