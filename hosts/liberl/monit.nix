{
  config,
  pkgs,
  lib,
  ...
}: {
  config = {
    services.prometheus.exporters = {
      zfs = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9002;
      };
      smartctl = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9003;
      };
    };
  };
}
