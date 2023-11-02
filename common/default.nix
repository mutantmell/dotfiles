{ config, options, pkgs, lib, utils, ... }:

let
  cfg = config.common.networking;
  network-data = pkgs.mmell.lib.common.network;
  parse-ipv4 = ipv4: lib.strings.splitString "." ipv4;
  parse-cidr4 = cidr: let
    split-cidr = lib.strings.splitString "/" cidr;
    ipv4-parts = parse-ipv4 (builtins.head cidr);
    mask-opt = builtins.tail cidr;
  in {
    ipv4 = ipv4-parts;
  } // (if mask-opt == [] then {} else {
    mask = builtins.head mask-opt;
  });
  format-ipv4 = builtins.concatStringsSep ".";
  replace-ipv4 = parts: ipv4: let
    num-parts = builtins.length parts;
  in (
    lib.lists.take (4 - num-parts) ipv4
  ) ++ parts;
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
    ipv4 = parse-ipv4 network-data.hosts.${cfg.hostname}.ipv4;
    gateway = format-ipv4 (replace-ipv4 [ "1" ] ipv4);
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
