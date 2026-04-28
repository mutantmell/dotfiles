{
  config,
  lib,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
in {
  config = lib.mkIf config.fluent-bit-agent.enable {
    assertions = [
      {
        assertion = builtins.elem config.networking.hostName net.monitoredHosts;
        message = "fluent-bit-agent.enable = true on '${config.networking.hostName}' but it is not listed in network.monitoredHosts";
      }
    ];

    tls-cert-client.enable = lib.mkDefault true;

    fluent-bit-agent = {
      lokiUrl = lib.mkDefault "https://tharbad.internal:3100/loki/api/v1/push";
      metricsUrl = lib.mkDefault "https://tharbad.internal:8427/api/v1/write";
      tls.certFile = lib.mkDefault "/var/lib/fleet-tls/client.crt";
      tls.keyFile = lib.mkDefault "/var/lib/fleet-tls/client.key";
    };

    users.users.fluent-bit.extraGroups = ["fleet-tls"];

    environment.persistence."/persist".directories = [
      {
        directory = "/var/lib/fluent-bit";
        user = "fluent-bit";
        group = "fluent-bit";
        mode = "0750";
      }
    ];
  };
}
