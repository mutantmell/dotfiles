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
in {
  options.fluent-bit-agent = {
    enable = lib.mkEnableOption "Fluent Bit agent (logs + metrics)";

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://tharbad.internal:3100/loki/api/v1/push";
      description = "Loki push API endpoint URL";
    };

    metricsUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://tharbad.internal:8427/api/v1/write";
      description = "vmauth remote_write endpoint URL";
    };

    authTokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the per-host bearer token.
        Used as Bearer auth on the metrics push output and as HTTP basic-auth
        password (hostname as username) on the Loki push output. Typically a
        sops-nix secret resolving to /run/secrets/observability-token.
      '';
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.node-exporter-client.enable;
        message = "fluent-bit-agent requires node-exporter-client.enable = true";
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
          storage = {
            path = "/var/lib/fluent-bit/storage/";
            sync = "normal";
            backlog.mem_limit = "16M";
          };
        };
        pipeline = {
          inputs =
            [
              {
                name = "systemd";
                tag = "host.log.*";
                db = "/var/lib/fluent-bit/systemd.db";
                # "db.sync" is a dotted flat key in fluent-bit; use string attr name.
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

          filters = [
            # Rename journald uppercase fields to lowercase Loki label names.
            # strip_underscores on the input already removed the leading underscore.
            {
              name = "modify";
              match = "host.log.*";
              rename = {
                SYSTEMD_UNIT = "unit";
                COMM = "comm";
                PRIORITY = "priority";
              };
            }
            # Add job and host labels used by Loki ruler queries.
            {
              name = "modify";
              match = "host.log.*";
              add = {
                job = "systemd-journal";
                host = config.networking.hostName;
              };
            }
          ];

          outputs = [
            {
              name = "loki";
              match = "host.log.*";
              inherit (lokiParsed) host;
              inherit (lokiParsed) port;
              inherit (lokiParsed) uri;
              label_keys = "$unit,$comm,$priority,$job,$host";
              line_format = "json";
              # Basic auth: username = hostname, password from token file via env var.
              # Fluent-bit substitutes ${VAR} in config at runtime from the environment.
              http_user = config.networking.hostName;
              http_passwd = "\${FLUENT_BIT_TOKEN}";
            }
            {
              name = "prometheus_remote_write";
              match = "host.metric.*";
              inherit (metricsParsed) host;
              inherit (metricsParsed) port;
              inherit (metricsParsed) uri;
              # Client-side host label; server-side vmauth extra_label enforces it.
              add_label = {host = config.networking.hostName;};
              # Bearer auth from env var; vmauth maps token → host identity.
              bearer_token = "\${FLUENT_BIT_TOKEN}";
            }
          ];
        };
      };
    };

    systemd.services.fluent-bit = {
      after = ["sops-nix.service"];
      wants = ["sops-nix.service"];
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "fluent-bit";
        Group = "fluent-bit";
        StateDirectory = "fluent-bit";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "fluent-bit";
        RuntimeDirectoryMode = "0750";
        # Run with elevated privileges to read the root-owned sops secret,
        # write the env file to RuntimeDirectory, then start as fluent-bit user.
        ExecStartPre = [
          "+${pkgs.writeShellScript "fluent-bit-env-setup" ''
            printf 'FLUENT_BIT_TOKEN=%s\n' "$(< '${cfg.authTokenFile}')" \
              > /run/fluent-bit/env
            chmod 640 /run/fluent-bit/env
            chown root:fluent-bit /run/fluent-bit/env
          ''}"
        ];
        EnvironmentFile = "/run/fluent-bit/env";
      };
    };

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
