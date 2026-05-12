{pkgs, ...}: let
  alertRules = {
    groups = [
      {
        name = "availability";
        rules = [
          {
            alert = "MetricsStale";
            expr = "time() - timestamp(node_uname_info) > 120";
            "for" = "0m";
            labels = {
              severity = "warning";
            };
            annotations = {
              summary = "{{ $labels.host }}: no fresh metrics for >2 minutes — agent may be down";
            };
          }
        ];
      }
      {
        name = "infrastructure";
        rules = [
          {
            alert = "DiskSpaceLow";
            expr = ''(node_filesystem_avail_bytes{fstype=~"ext4|btrfs|xfs|zfs"} / node_filesystem_size_bytes{fstype=~"ext4|btrfs|xfs|zfs"}) < 0.10'';
            "for" = "5m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.host }} disk {{ $labels.mountpoint }} is over 90% full";
          }
          {
            alert = "HighMemoryUsage";
            expr = "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.90";
            "for" = "5m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.host }} memory usage is above 90%";
          }
          {
            alert = "ZFSPoolDegraded";
            expr = ''node_zfs_zpool_state{state!="online"} > 0'';
            "for" = "1m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.host }} ZFS pool {{ $labels.zpool }} is degraded";
          }
          {
            alert = "SystemdUnitFailed";
            expr = ''node_systemd_unit_state{state="failed"} == 1'';
            "for" = "5m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.host }} systemd unit {{ $labels.name }} has failed";
          }
          {
            alert = "HighCPUUsage";
            expr = ''100 - (avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90'';
            "for" = "10m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.host }} CPU usage above 90% for 10 minutes";
          }
          {
            alert = "HostRebooted";
            expr = "(time() - node_boot_time_seconds) < 300";
            "for" = "0m";
            labels.severity = "warning";
            annotations.summary = "{{ $labels.host }} rebooted less than 5 minutes ago";
          }
        ];
      }
      {
        name = "service-health";
        rules = [
          {
            alert = "VmAlertRuleEvalFailure";
            expr = "rate(vmalert_iteration_errors_total[5m]) > 0";
            "for" = "5m";
            labels.severity = "warning";
            annotations.summary = "vmalert rule evaluation failures detected";
          }
          {
            alert = "IngestAuthFailures";
            expr = ''rate(vmauth_user_request_errors_total{reason="bad_auth"}[5m]) > 0'';
            "for" = "0m";
            labels.severity = "warning";
            annotations.summary = "vmauth: bad bearer token rejections detected";
          }
        ];
      }
      {
        name = "victorialogs";
        rules = [
          {
            # fluent-bit's prometheus_remote_write doesn't generate `up`, so
            # check freshness of an always-present VL metric instead.
            alert = "VictoriaLogsDown";
            expr = "time() - timestamp(vlstorage_rows) > 120";
            "for" = "2m";
            labels.severity = "critical";
            annotations.summary = "VictoriaLogs /metrics stale for >2m — log ingestion likely broken";
          }
          {
            alert = "VictoriaLogsIngestionStalled";
            expr = ''rate(vl_rows_ingested_total[10m]) == 0'';
            "for" = "10m";
            labels.severity = "warning";
            annotations.summary = "VictoriaLogs ingestion rate is zero for 10 minutes";
          }
          {
            alert = "VictoriaLogsHTTPErrors";
            expr = ''rate(vl_http_request_errors_total[5m]) > 0'';
            "for" = "5m";
            labels.severity = "warning";
            annotations.summary = "VictoriaLogs HTTP request errors detected (insert or query path)";
          }
        ];
      }
    ];
  };
in {
  services.victoriametrics = {
    enable = true;
    listenAddress = "127.0.0.1:8428";
    retentionPeriod = "90d";
    extraOptions = [
      "-maxLabelsPerTimeseries=50"
    ];
  };

  # vmalert — rule evaluation against vmsingle; fires to Alertmanager.
  services.vmalert.instances."" = {
    enable = true;
    settings = {
      "datasource.url" = "http://127.0.0.1:8428";
      "notifier.url" = ["http://127.0.0.1:9093"];
      "remoteWrite.url" = "http://127.0.0.1:8428";
      "evaluationInterval" = "1m";
    };
    rules = alertRules;
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/victoriametrics";
      user = "victoriametrics";
      group = "victoriametrics";
      mode = "0700";
    }
  ];
}
