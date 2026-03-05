{ config, ... }:
{
  networking.firewall.allowedTCPPorts = [ 9093 ];

  services.prometheus.alertmanager = {
    enable = true;
    port = 9093;
    configuration = {
      route = {
        receiver = "ntfy-default";
        group_by = [ "alertname" "instance" ];
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
          webhook_configs = [{ url = "http://localhost:2586/infra-critical"; }];
        }
        {
          name = "ntfy-security";
          webhook_configs = [{ url = "http://localhost:2586/security"; }];
        }
        {
          name = "ntfy-cicd";
          webhook_configs = [{ url = "http://localhost:2586/cicd"; }];
        }
        {
          name = "ntfy-default";
          webhook_configs = [{ url = "http://localhost:2586/services"; }];
        }
      ];
    };
  };

  # Tell Prometheus where to find Alertmanager
  services.prometheus.alertmanagers = [{
    static_configs = [{
      targets = [ "localhost:9093" ];
    }];
  }];

  # Phase 1 alert rules
  services.prometheus.rules = [
    (builtins.toJSON {
      groups = [{
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
            expr = "(node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.10";
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
        ];
      }];
    })
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/alertmanager";
      user = "alertmanager";
      group = "alertmanager";
    }
  ];
}
