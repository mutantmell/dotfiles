{ config, pkgs, ...}:

{

  networking.nat.enable = true;
  networking.nat.externalInterface = "ens3";
  networking.nat.internalInterfaces = [ "wg0" ];
  networking.firewall = {
    allowedUDPPorts = [ 51820 ];
  };

  networking.wireguard.interfaces =
  let
    addr = octlet: "10.100.0.${octlet}";
  in {
    wg0 = {
      ips = [ (addr "1/24") ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard-key.path;

      peers = [
        {
          publicKey = "tCPBgrj+RdSjknIrhdATr45Ptd0ecio9JWEXyiIsm0Y=";
          allowedIPs = [ (addr "2/32") ];
        }
      ];
    };
  };
  
}
