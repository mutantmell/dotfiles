{ config, options, pkgs, lib, ... }:

let
  cfg = config.common.networking;
  network-data = pkgs.mmell.lib.common.data.network;
  nw-lib = pkgs.mmell.lib.common.network;
in {
  options.common.networking = {
    enable = lib.mkEnableOption "Common Networking Configuration";
    hostname = lib.mkOption {
      type = lib.types.str;
    };
    interface = lib.mkOption {
      type = lib.types.str;
    };
  };

  config = lib.mkIf cfg.enable (let
    ipv4 = nw-lib.parsing.ipv4 network-data.hosts.${cfg.hostname}.ipv4;
    gateway = nw-lib.formatting.ipv4 (nw-lib.replace-ipv4 [ "1" ] ipv4);
  in {
    networking.hostName = cfg.hostname;
    networking.useNetworkd = true;
    networking.nftables.enable = true;
    networking.interfaces.${cfg.interface} = {
      useDHCP = false;
      ipv4.addresses = [{
        address = network-data.hosts.${cfg.hostname}.ipv4;
        prefixLength = 24;
      }];
    };
    networking.defaultGateway.address = gateway;
    networking.defaultGateway.interface = cfg.interface;
    networking.nameservers = [ gateway ];

    services.avahi = {
      enable = true;
      nssmdns = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };
  });
}
