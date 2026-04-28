{config, ...}: let
  # Generate a node_exporter scrape config from a hostname
  mkNodeScrape = name: port: {
    job_name = "${name}_node";
    static_configs = [{targets = ["${name}.internal:${toString port}"];}];
  };

  # Standard node_exporter targets (port 9100)
  nodeTargets = [
    # Parent hosts
    "thebeyond"
    "calvard"
    "erebonia"
    # Management zone guests
    "phantasma"
    "basel"
    "messeldam"
    # DMZ zone guests
    "langport"
    "creil"
    "oracion"
    "zeiss"
    "saint-arkh"
    "trista"
    # Lab zone guests
    "bose"
    "edith"
  ];
in {
  networking.firewall.allowedTCPPorts = [
    config.services.prometheus.port
  ];

  node-exporter-client.enable = true;

  services.prometheus = {
    enable = true;
    port = 9090;
    scrapeConfigs =
      [
        # Self-scrape: node_exporter
        {
          job_name = "tharbad_node";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.node-exporter-client.port}"];
            }
          ];
          relabel_configs = [
            {
              target_label = "instance";
              replacement = "tharbad.internal:${toString config.node-exporter-client.port}";
            }
          ];
        }
        # Self-scrape: prometheus
        {
          job_name = "prometheus";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.prometheus.port}"];
            }
          ];
          relabel_configs = [
            {
              target_label = "instance";
              replacement = "tharbad.internal:${toString config.services.prometheus.port}";
            }
          ];
        }
        # Self-scrape: loki
        {
          job_name = "loki";
          static_configs = [
            {
              targets = ["127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}"];
            }
          ];
          relabel_configs = [
            {
              target_label = "instance";
              replacement = "tharbad.internal:${toString config.services.loki.configuration.server.http_listen_port}";
            }
          ];
        }
      ]
      ++ (map (name: mkNodeScrape name 9100) nodeTargets)
      ++ [
        # Liberl: non-standard ports for multiple exporters
        (mkNodeScrape "liberl" 9001)
        {
          job_name = "liberl_zfs";
          static_configs = [{targets = ["liberl.internal:9002"];}];
        }
        {
          job_name = "liberl_smartctl";
          static_configs = [{targets = ["liberl.internal:9003"];}];
        }
      ];
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/" + config.services.prometheus.stateDir;
      user = "prometheus";
      inherit (config.users.users.prometheus) group;
    }
  ];
}
