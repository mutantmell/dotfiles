{ config, pkgs, ...}:

{

  networking.firewall = {
    allowedUDPPorts = [ 58156 ];
    interfaces."wg0".allowedTCPPorts = [ 22 ];
  };

  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ "10.100.1.1/24" "10.100.20.10/24" ];
      listenPort = 58156;
      privateKeyFile = config.sops.secrets.wireguard-key.path;

      peers = [
        {
          publicKey = "6Kb9OxV5mmCDt8GNTYTQi745sXI/ON7R9ZKnhuXPKiA=";
          allowedIPs = [ "10.100.1.2/32" "10.0.0.0/16" ];
        }
        {
          publicKey = "8VUwFlyw+Rj6mXDbzYV51lgqWrWskFEcwNR/6M85fg0=";
          allowedIPs = [ "10.100.20.0/24" ];
        }
      ];
    };
  };
}
