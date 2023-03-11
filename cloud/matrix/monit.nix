{ config, pkgs, lib, ... }:
{
  config = {
    networking.firewall.interfaces."wg0".allowedTCPPorts = [
      config.services.prometheus.exporters.node.port
    ];
    services.prometheus.exporters = {
      node = {
        enable = true;
        enabledCollectors = [ "systemd" ];
        port = 9001;
      };
    };
  };
}
