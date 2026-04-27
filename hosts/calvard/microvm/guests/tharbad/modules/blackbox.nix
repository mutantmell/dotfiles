{pkgs, ...}: let
  blackboxConfig = pkgs.writeText "blackbox.yml" (builtins.toJSON {
    modules = {
      tcp_ssh = {
        prober = "tcp";
        timeout = "5s";
        tcp = {
          preferred_ip_protocol = "ip4";
        };
      };
    };
  });
in {
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9115;
    configFile = blackboxConfig;
  };
}
