{ config, pkgs, lib, ... }:
{
  config = {
    networking.firewall.allowedTCPPorts = [
      config.services.prometheus.exporters.node.port
      config.services.prometheus.exporters.zfs.port
      config.services.prometheus.exporters.smartctl.port
    ];
    services.prometheus.exporters = {
      node = {
        enable = true;
        enabledCollectors = [ "systemd" ];
        port = 9001;
      };
      zfs = {
        enable = true;
        port = 9002;
      };
      smartctl = {
        enable = true;
        port = 9003;
      };
    };
  };
}
