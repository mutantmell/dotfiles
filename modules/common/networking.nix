{
  config,
  options,
  pkgs,
  lib,
  ...
}: let
  cfg = config.common.networking;
  network-data = pkgs.mmell.lib.data.network;
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
    hostInfo = network-data.forHost cfg.hostname;
    gateway = hostInfo.zone.gateway4;
  in
    lib.mkMerge [
      {
        networking.hostName = cfg.hostname;
        networking.useNetworkd = true;
        # TODO: use systemd network interface, rather than networking dsl
        networking.interfaces.${cfg.interface} = {
          useDHCP = false;
          ipv4.addresses = [
            {
              address = network-data.hosts.${cfg.hostname}.ipv4;
              prefixLength = hostInfo.zone.prefixLength4;
            }
          ];
        };
        networking.defaultGateway.address = gateway;
        networking.defaultGateway.interface = cfg.interface;
        networking.nameservers = [gateway];
        services.resolved.enable = true;
      }
      (lib.mkIf cfg.extraHosts.enable {
        networking.extraHosts = network-data.mkExtraHosts cfg.extraHosts.hosts;
      })
    ]);
}
