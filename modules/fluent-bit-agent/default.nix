{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.fluent-bit-agent;

  parseUrl = url: let
    withoutScheme = lib.removePrefix "http://" (lib.removePrefix "https://" url);
    hostPort = lib.head (lib.splitString "/" withoutScheme);
    pathParts = lib.tail (lib.splitString "/" withoutScheme);
    uri = "/" + lib.concatStringsSep "/" pathParts;
    hostParts = lib.splitString ":" hostPort;
    host = lib.head hostParts;
    port =
      if lib.length hostParts > 1
      then lib.toInt (lib.elemAt hostParts 1)
      else 80;
  in {inherit host port uri;};

  lokiParsed = parseUrl cfg.lokiUrl;
  metricsParsed = parseUrl cfg.metricsUrl;

  hasTls = cfg.tls.certFile != null;
  tlsConfig = lib.optionalAttrs hasTls {
    tls = "on";
    "tls.crt_file" = cfg.tls.certFile;
    "tls.key_file" = cfg.tls.keyFile;
  };
in {
  options.fluent-bit-agent = {
    enable = lib.mkEnableOption "Fluent Bit agent (logs + metrics)";

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      description = "Loki push API endpoint URL";
    };

    metricsUrl = lib.mkOption {
      type = lib.types.str;
      description = "VictoriaMetrics remote_write endpoint URL";
    };

    tls.certFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to TLS client certificate file for mTLS auth on push endpoints.";
    };

    tls.keyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to TLS client private key file for mTLS auth on push endpoints.";
    };

    extraInputs = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = ''
        Additional Fluent Bit inputs for hosts with extra local exporters
        bound to 127.0.0.1 (e.g., zfs_exporter, smartctl_exporter). Tags
        should start with "host.metric." to route to vmsingle.
      '';
    };

    extraFilters = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = ''
        Additional Fluent Bit filters appended after the default modify filters.
        Useful for injecting per-stream labels (e.g., target labels for blackbox probes).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.node-exporter-client.enable;
        message = "fluent-bit-agent requires node-exporter-client.enable = true";
      }
      {
        assertion = (cfg.tls.certFile != null) == (cfg.tls.keyFile != null);
        message = "fluent-bit-agent: tls.certFile and tls.keyFile must both be set or both be null";
      }
    ];

    users.users.fluent-bit = {
      isSystemUser = true;
      group = "fluent-bit";
      extraGroups = ["systemd-journal"];
      description = "Fluent Bit log and metrics agent";
    };
    users.groups.fluent-bit = {};

    services.fluent-bit = {
      enable = true;
      settings = {
        service = {
          flush = 5;
          log_level = "info";
          "storage.path" = "/var/lib/fluent-bit/storage/";
          "storage.sync" = "normal";
          "storage.backlog.mem_limit" = "16M";
        };
        pipeline = {
          inputs =
            [
              {
                name = "systemd";
                tag = "host.log.*";
                db = "/var/lib/fluent-bit/systemd.db";
                "db.sync" = "normal";
                read_from_tail = "off";
                strip_underscores = "on";
              }
              {
                name = "prometheus_scrape";
                tag = "host.metric.node";
                host = "127.0.0.1";
                inherit (config.node-exporter-client) port;
                scrape_interval = "15";
              }
              {
                name = "fluentbit_metrics";
                tag = "host.metric.agent";
                scrape_interval = "30";
              }
            ]
            ++ cfg.extraInputs;

          filters =
            [
              {
                name = "modify";
                match = "host.log.*";
                rename = [
                  "SYSTEMD_UNIT unit"
                  "COMM comm"
                  "PRIORITY priority"
                ];
              }
              {
                name = "modify";
                match = "host.log.*";
                add = [
                  "job systemd-journal"
                  "host ${config.networking.hostName}"
                ];
              }
            ]
            ++ cfg.extraFilters;

          outputs = [
            ({
                name = "loki";
                match = "host.log.*";
                inherit (lokiParsed) host port uri;
                label_keys = "$unit,$comm,$priority,$job,$host";
                line_format = "json";
              }
              // tlsConfig)
            ({
                name = "prometheus_remote_write";
                match = "host.metric.*";
                inherit (metricsParsed) host port uri;
                # nginx's extra_label overrides this for mTLS hosts; needed for
                # hosts writing directly to vmsingle without a proxy.
                add_label = ["host ${config.networking.hostName}"];
              }
              // tlsConfig)
          ];
        };
      };
    };

    systemd.services.fluent-bit = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "fluent-bit";
        Group = "fluent-bit";
        StateDirectory = "fluent-bit";
        StateDirectoryMode = "0750";
      };
    };
  };
}
