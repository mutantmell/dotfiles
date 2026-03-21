{config, ...}: {
  networking.firewall.allowedTCPPorts = [9093];

  services.prometheus.alertmanager = {
    enable = true;
    port = 9093;
    configuration = {
      route = {
        receiver = "ntfy-default";
        group_by = ["alertname" "instance"];
        group_wait = "30s";
        group_interval = "5m";
        repeat_interval = "4h";
        routes = [
          {
            match.severity = "critical";
            receiver = "ntfy-critical";
            repeat_interval = "1h";
          }
          {
            match.category = "security";
            receiver = "ntfy-security";
            repeat_interval = "2h";
          }
          {
            match.category = "cicd";
            receiver = "ntfy-cicd";
          }
        ];
      };
      receivers = [
        {
          name = "ntfy-critical";
          webhook_configs = [{url = "http://localhost:2586/infra-critical";}];
        }
        {
          name = "ntfy-security";
          webhook_configs = [{url = "http://localhost:2586/security";}];
        }
        {
          name = "ntfy-cicd";
          webhook_configs = [{url = "http://localhost:2586/cicd";}];
        }
        {
          name = "ntfy-default";
          webhook_configs = [{url = "http://localhost:2586/services";}];
        }
      ];
    };
  };

  # Tell Prometheus where to find Alertmanager
  services.prometheus.alertmanagers = [
    {
      static_configs = [
        {
          targets = ["localhost:9093"];
        }
      ];
    }
  ];

  # Alert rules
  services.prometheus.rules = [
    (builtins.toJSON {
      groups = [
        {
          name = "infrastructure";
          rules = [
            {
              alert = "HostDown";
              expr = "up == 0";
              "for" = "2m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.instance }} is unreachable";
            }
            {
              alert = "DiskSpaceLow";
              expr = ''(node_filesystem_avail_bytes{fstype=~"ext4|btrfs|xfs|zfs"} / node_filesystem_size_bytes{fstype=~"ext4|btrfs|xfs|zfs"}) < 0.10'';
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.instance }} disk {{ $labels.mountpoint }} is over 90% full";
            }
            {
              alert = "HighMemoryUsage";
              expr = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.90";
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.instance }} memory usage is above 90%";
            }
            {
              alert = "ZFSPoolDegraded";
              expr = ''node_zfs_zpool_state{state!="online"} > 0'';
              "for" = "1m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.instance }} ZFS pool {{ $labels.zpool }} is degraded";
            }
            {
              alert = "SystemdUnitFailed";
              expr = ''node_systemd_unit_state{state="failed"} == 1'';
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.instance }} systemd unit {{ $labels.name }} has failed";
            }
            {
              alert = "HighCPUUsage";
              expr = ''100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90'';
              "for" = "10m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.instance }} CPU usage above 90% for 10 minutes";
            }
            {
              alert = "HostRebooted";
              expr = "(time() - node_boot_time_seconds) < 300";
              "for" = "0m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.instance }} rebooted less than 5 minutes ago";
            }
          ];
        }
        {
          name = "service-health";
          rules = [
            {
              alert = "SlowScrape";
              expr = "scrape_duration_seconds > 10";
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.instance }} ({{ $labels.job }}) scrape taking {{ $value }}s";
            }
            {
              alert = "PrometheusRuleEvalFailure";
              expr = "rate(prometheus_rule_evaluation_failures_total[5m]) > 0";
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "Prometheus rule evaluation failures detected";
            }
            {
              alert = "LokiRequestErrors";
              expr = ''rate(loki_request_duration_seconds_count{status_code=~"5.."}[5m]) > 0'';
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "Loki returning server errors";
            }
            {
              alert = "LokiIngestionLag";
              expr = "loki_ingester_chunk_age_seconds_sum / loki_ingester_chunk_age_seconds_count > 900";
              "for" = "10m";
              labels.severity = "warning";
              annotations.summary = "Loki chunk age averaging above 15 minutes — ingestion may be lagging";
            }
          ];
        }
      ];
    })
  ];

  environment.persistence."/persist".directories = [
    "/var/lib/private/alertmanager"
  ];
}
