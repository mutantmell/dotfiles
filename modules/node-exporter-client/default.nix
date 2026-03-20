{
  config,
  lib,
  ...
}: let
  cfg = config.node-exporter-client;
in {
  options.node-exporter-client = {
    enable = lib.mkEnableOption "Prometheus node_exporter metrics";
    port = lib.mkOption {
      type = lib.types.port;
      default = 9100;
      description = "Port for node_exporter to listen on";
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      inherit (cfg) port;
      enabledCollectors = ["systemd"];
    };
    networking.firewall.allowedTCPPorts = [cfg.port];
  };
}
