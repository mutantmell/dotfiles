{
  config,
  pkgs,
  lib,
  ...
}: let
  # All fleet hosts that push metrics and logs to tharbad.
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

  vmauthConfigPath = "/etc/vmauth/auth.yml";

  alertRules = {
    groups = [
      {
        name = "availability";
        rules = [
          {
            alert = "HostUnreachable";
            expr = ''probe_success{job="blackbox-ssh"} == 0'';
            "for" = "2m";
            labels = {
              severity = "critical";
            };
            annotations = {
              summary = "{{ $labels.host }}: SSH probe failing — host may be down";
            };
          }
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
          {
            alert = "IngestAuthFailures";
            expr = ''rate(vmauth_user_request_errors_total{reason="bad_auth"}[5m]) > 0'';
            "for" = "0m";
            labels.severity = "warning";
            annotations.summary = "vmauth: bad bearer token rejections detected";
          }
          {
            alert = "LokiAuthFailures";
            expr = ''rate(nginx_http_requests_total{server="loki",status="401"}[5m]) > 0'';
            "for" = "0m";
            labels.severity = "warning";
            annotations.summary = "Loki nginx: 401 auth failures detected on push endpoint";
          }
        ];
      }
    ];
  };
in {
  # vmsingle — metrics TSDB (loopback-only; vmauth is the external face).
  services.victoriametrics = {
    enable = true;
    listenAddress = "127.0.0.1:8428";
    retentionPeriod = "90d";
    extraOptions = [
      # Reject samples older than 5 min or newer than 1 min (anti-replay).
      "-search.maxStalenessInterval=5m"
      "-maxLabelsPerTimeseries=50"
    ];
  };

  # vmauth — bearer-token auth gateway; maps token → identity via extra_label URL.
  # Option A (tested in Phase 1): vmsingle's extra_label URL param overrides
  # incoming host label, so no vmagent needed in the chain.
  users.users.vmauth = {
    isSystemUser = true;
    group = "vmauth";
    description = "vmauth metrics auth proxy";
  };
  users.groups.vmauth = {};

  # Generate vmauth config from sops-decrypted per-host tokens.
  sops.templates."vmauth-auth" = {
    path = vmauthConfigPath;
    owner = "vmauth";
    mode = "0400";
    content = let
      mkEntry = host: ''
        - bearer_token: "${config.sops.placeholder."host-tokens/${host}"}"
          url_prefix: "http://127.0.0.1:8428/api/v1/write?extra_label=host=${host}"
      '';
    in ''
      users:
      ${lib.concatMapStrings mkEntry fleetHosts}
    '';
  };

  systemd.tmpfiles.rules = [
    "d /etc/vmauth 0750 vmauth vmauth -"
  ];

  systemd.services.vmauth = {
    description = "vmauth metrics authentication proxy";
    wantedBy = ["multi-user.target"];
    after = ["network.target" "sops-nix.service" "victoriametrics.service"];
    wants = ["sops-nix.service"];
    requires = ["victoriametrics.service"];
    serviceConfig = {
      User = "vmauth";
      Group = "vmauth";
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "5s";
      ExecStart = "${pkgs.victoriametrics}/bin/vmauth -auth.config=${vmauthConfigPath} -httpListenAddr=:8427";
      # Hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [];
    };
  };

  networking.firewall.allowedTCPPorts = [8427];

  # vmalert — rule evaluation against vmsingle; fires to Alertmanager.
  services.vmalert.instances."" = {
    enable = true;
    settings = {
      "datasource.url" = "http://127.0.0.1:8428";
      "notifier.url" = ["http://127.0.0.1:9093"];
      "remoteWrite.url" = "http://127.0.0.1:8428/api/v1/write";
      "evaluationInterval" = "1m";
    };
    rules = alertRules;
  };

  # Sops secrets — host-token table for vmauth and Loki htpasswd.
  # Plaintext tokens for vmauth live in host-tokens/<hostname>;
  # htpasswd (pre-bcrypt-hashed) lives in loki-htpasswd.
  sops.secrets =
    lib.listToAttrs (
      map (host: {
        name = "host-tokens/${host}";
        value = {};
      })
      fleetHosts
    )
    // {
      "loki-htpasswd" = {};
    };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/victoriametrics";
      user = "victoriametrics";
      group = "victoriametrics";
      mode = "0700";
    }
  ];
}
