{ config, options, pkgs, lib, ... }:

let
  cfg = config.common.networking;
  network-data = pkgs.mmell.lib.data.network;
  nw-lib = pkgs.mmell.lib.network;
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
    cidr = nw-lib.parsing.cidr4 network-data.hosts.${cfg.hostname}.ipv4;
    gateway = cidr.ipv4.replace [ "1" ];
  in {
    networking.hostName = cfg.hostname;
    networking.useNetworkd = true;
    networking.nftables.enable = true;
    # TODO: use systemd network interface
    networking.interfaces.${cfg.interface} = {
      useDHCP = false;
      ipv4.addresses = [{
        address = network-data.hosts.${cfg.hostname}.ipv4;
        prefixLength = cidr.mask or 24;
      }];
    };
    networking.defaultGateway.address = gateway;
    networking.defaultGateway.interface = cfg.interface;
    networking.nameservers = [ gateway ];

    # use resolved for hostname resolution, avahi for mdns publishing
    services.resolved.enable = true;
    services.avahi = {
      enable = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };
  });
}
