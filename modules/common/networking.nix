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
    extraHosts = lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption "add certain hosts to extra-hosts";
        options.hosts = lib.mkOption {
          type = lib.types.nonEmptyListOf (lib.types.enum (
            builtins.attrNames network-data.hosts
          ));
          default = builtins.attrNames network-data.hosts;
        };
      };
      default = {};
    };
  };

  config = lib.mkIf cfg.enable (let
    cidr = nw-lib.parsing.cidr4 network-data.hosts.${cfg.hostname}.ipv4;
    gateway = cidr.ipv4.replace [ "1" ];
  in lib.mkMerge [
    {
      networking.hostName = cfg.hostname;
      networking.useNetworkd = true;
      networking.nftables.enable = true;
      # TODO: use systemd network interface, rather than networking dsl
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
      services.resolved.enable = true;
    }
    (lib.mkIf cfg.extraHosts.enable {
      networking.extraHosts = lib.strings.concatStringsSep "\n" (
        builtins.map (host: "${network-data.hosts.${host}.ipv4} ${host}.local") cfg.extraHosts.hosts
      );
    })
  ]);
}
