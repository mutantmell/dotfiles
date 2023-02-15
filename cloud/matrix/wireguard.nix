{ config, pkgs, ...}:

{

  networking.nat = {
    #enable = true;
    externalInterface = "ens3";
    internalInterfaces = [ "wg0" ];
  };
  networking.firewall = {
    allowedUDPPorts = [ 51895 ];
  };

  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ "10.100.1.1/24" ];
      listenPort = 51895;
      privateKeyFile = config.sops.secrets.wireguard-key.path;

      peers = [
        {
          publicKey = "6Kb9OxV5mmCDt8GNTYTQi745sXI/ON7R9ZKnhuXPKiA=";
          allowedIPs = [ "10.100.1.2/32" ];
        }
      ];
    };
  };
}
