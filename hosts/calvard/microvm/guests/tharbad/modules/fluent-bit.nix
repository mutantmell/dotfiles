{
  config,
  pkgs,
  lib,
  ...
}: let
  # Fleet hosts to TCP-probe via blackbox_exporter.
  fleetHosts = [
    "thebeyond"
    "calvard"
    "erebonia"
    "liberl"
    "tharbad"
    "phantasma"
    "basel"
    "messeldam"
    "langport"
    "creil"
    "oracion"
    "zeiss"
    "saint-arkh"
    "trista"
    "bose"
    "edith"
  ];

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
in {
  # Tharbad's own fluent-bit agent. Uses the fleet module but routes logs
  # directly to local Loki (bypassing the nginx auth proxy at :3100)
  # and metrics to local vmauth for label pinning.
  fluent-bit-agent = {
    enable = true;
    # Direct to Loki's listen port — no nginx auth, Loki has auth_enabled=false.
    lokiUrl = "http://127.0.0.1:${toString lokiPort}/loki/api/v1/push";
    # Route metrics through vmauth for host label enforcement.
    metricsUrl = "http://127.0.0.1:8427/api/v1/write";
    authTokenFile = config.sops.secrets."observability-token".path;
    extraInputs =
      blackboxInputs
      ++ [
        # Loki self-metrics
        {
          name = "prometheus_scrape";
          tag = "host.metric.loki";
          host = "127.0.0.1";
          port = lokiPort;
          metrics_path = "/metrics";
          scrape_interval = "15";
        }
        # vmsingle self-metrics
        {
          name = "prometheus_scrape";
          tag = "host.metric.vmsingle";
          host = "127.0.0.1";
          port = 8428;
          metrics_path = "/metrics";
          scrape_interval = "15";
        }
        # vmauth self-metrics
        {
          name = "prometheus_scrape";
          tag = "host.metric.vmauth";
          host = "127.0.0.1";
          port = 8427;
          metrics_path = "/metrics";
          scrape_interval = "15";
        }
      ];
  };
}
