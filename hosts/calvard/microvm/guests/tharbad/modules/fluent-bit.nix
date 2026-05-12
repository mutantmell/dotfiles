{
  config,
  pkgs,
  lib,
  ...
}: {
  # Tharbad's own node_exporter — scraped locally by fluent-bit-agent's default
  # `host.metric.node` input and pushed to vmsingle alongside fleet metrics.
  node-exporter-client.enable = true;

  fluent-bit-agent = {
    enable = true;
    # Local traffic goes directly to VictoriaLogs and vmsingle — no mTLS needed.
    lokiUrl = "http://127.0.0.1:9428/insert/loki/api/v1/push";
    metricsUrl = "http://127.0.0.1:8428/api/v1/write";
    tls.certFile = lib.mkForce null;
    tls.keyFile = lib.mkForce null;
    extraInputs = [
      {
        name = "prometheus_scrape";
        tag = "host.metric.vmsingle";
        host = "127.0.0.1";
        port = 8428;
        metrics_path = "/metrics";
        scrape_interval = "15";
      }
      {
        name = "prometheus_scrape";
        tag = "host.metric.victorialogs";
        host = "127.0.0.1";
        port = 9428;
        metrics_path = "/metrics";
        scrape_interval = "15";
      }
      {
        name = "prometheus_scrape";
        tag = "host.metric.alertmanager";
        host = "127.0.0.1";
        port = config.services.prometheus.alertmanager.port;
        metrics_path = "/metrics";
        scrape_interval = "15";
      }
    ];
  };
}
