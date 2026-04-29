{
  config,
  pkgs,
  lib,
  ...
}: let
  fleetHosts = pkgs.mmell.lib.data.network.monitoredHosts;

  lokiPort = config.services.loki.configuration.server.http_listen_port;

  blackboxInputs =
    map (host: {
      name = "prometheus_scrape";
      tag = "host.metric.blackbox.${host}";
      host = "127.0.0.1";
      port = 9115;
      metrics_path = "/probe?module=tcp_ssh&target=${host}.internal:22";
      scrape_interval = "30";
    })
    fleetHosts;

  blackboxFilters =
    map (host: {
      name = "modify";
      match = "host.metric.blackbox.${host}";
      add = ["target ${host}.internal:22"];
    })
    fleetHosts;
in {
  fluent-bit-agent = {
    enable = true;
    # Local traffic goes directly to Loki and vmsingle — no mTLS needed.
    lokiUrl = "http://127.0.0.1:${toString lokiPort}/loki/api/v1/push";
    metricsUrl = "http://127.0.0.1:8428/api/v1/write";
    tls.certFile = lib.mkForce null;
    tls.keyFile = lib.mkForce null;
    extraInputs =
      blackboxInputs
      ++ [
        {
          name = "prometheus_scrape";
          tag = "host.metric.loki";
          host = "127.0.0.1";
          port = lokiPort;
          metrics_path = "/metrics";
          scrape_interval = "15";
        }
        {
          name = "prometheus_scrape";
          tag = "host.metric.vmsingle";
          host = "127.0.0.1";
          port = 8428;
          metrics_path = "/metrics";
          scrape_interval = "15";
        }
      ];
    extraFilters = blackboxFilters;
  };
}
