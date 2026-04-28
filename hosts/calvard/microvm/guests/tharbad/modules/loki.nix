{
  pkgs,
  config,
  ...
}: let
  # Number of hosts expected to be shipping logs (parent hosts + guests)
  # thebeyond(1) + calvard(1) + erebonia(1) + liberl(1) +
  # tharbad(1) + phantasma(1) + basel(1) + messeldam(1) +
  # langport(1) + creil(1) + oracion(1) + zeiss(1) +
  # saint-arkh(1) + trista(1) + edith(1) + bose(1) = 16
  expectedHosts = 16;

  # Security alert rules evaluated by Loki's ruler against log streams
  securityRules = pkgs.writeText "security-alerts.yaml" (builtins.toJSON {
    groups = [
      {
        name = "security";
        rules = [
          {
            alert = "SSHBruteForce";
            expr = ''sum by (host) (count_over_time({unit="sshd.service"} |~ "Failed password|authentication failure|Invalid user|Connection closed by authenticating user" [5m])) > 10'';
            "for" = "0m";
            labels = {
              severity = "warning";
              category = "security";
            };
            annotations = {
              summary = "{{ $labels.host }}: more than 10 SSH auth failures in 5 minutes";
            };
          }
          {
            alert = "SSHBruteForceExtreme";
            expr = ''sum by (host) (count_over_time({unit="sshd.service"} |~ "Failed password|authentication failure|Invalid user|Connection closed by authenticating user" [5m])) > 50'';
            "for" = "0m";
            labels = {
              severity = "critical";
              category = "security";
            };
            annotations = {
              summary = "{{ $labels.host }}: more than 50 SSH auth failures in 5 minutes — active brute force";
            };
          }
          {
            alert = "SudoFailure";
            expr = ''sum by (host) (count_over_time({comm="sudo"} |~ "authentication failure|incorrect password" [10m])) > 0'';
            "for" = "0m";
            labels = {
              severity = "warning";
              category = "security";
            };
            annotations = {
              summary = "{{ $labels.host }}: failed sudo authentication attempt";
            };
          }
          {
            alert = "HighPriorityLogs";
            expr = ''sum by (host) (count_over_time({priority=~"[0-2]"}[5m])) > 0'';
            "for" = "0m";
            labels = {
              severity = "critical";
              category = "security";
            };
            annotations = {
              summary = "{{ $labels.host }}: emergency/alert/critical log messages detected";
            };
          }
        ];
      }
      {
        name = "log-health";
        rules = [
          {
            alert = "FleetLogGap";
            expr = "count(count_over_time({job=\"systemd-journal\"}[15m])) < ${toString expectedHosts}";
            "for" = "15m";
            labels = {
              severity = "warning";
            };
            annotations = {
              summary = "Fewer than ${toString expectedHosts} hosts shipping logs to Loki — check fluent-bit fleet";
            };
          }
        ];
      }
    ];
  });
in {
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;

      server = {
        http_listen_port = 3101;
        http_listen_address = "127.0.0.1";
      };

      common = {
        path_prefix = "/var/lib/loki";
        ring = {
          instance_addr = "127.0.0.1";
          kvstore.store = "inmemory";
        };
        replication_factor = 1;
      };

      schema_config.configs = [
        {
          from = "2025-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];

      storage_config.filesystem.directory = "/var/lib/loki/chunks";

      limits_config = {
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
      };

      ruler = {
        storage = {
          type = "local";
          local.directory = "/var/lib/loki/rules";
        };
        rule_path = "/var/lib/loki/rules-tmp";
        alertmanager_url = "http://localhost:9093";
        ring = {
          kvstore.store = "inmemory";
        };
        enable_api = true;
      };
    };
  };

  # Place ruler alert files where Loki expects them.
  # With auth_enabled=false, Loki uses tenant "fake".
  systemd.tmpfiles.rules = [
    "d /var/lib/loki/rules/fake 0750 loki loki -"
    "L+ /var/lib/loki/rules/fake/security-alerts.yaml - - - - ${securityRules}"
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/loki";
      user = "loki";
      group = "loki";
    }
  ];
}
