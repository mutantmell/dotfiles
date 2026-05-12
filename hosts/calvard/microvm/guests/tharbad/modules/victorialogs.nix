{
  pkgs,
  lib,
  ...
}: let
  expectedHosts = 16;
  vlPort = 9428;
  vlAlertPort = 8881;

  securityRules = pkgs.writeText "vlogs-security-alerts.yaml" (builtins.toJSON {
    groups = [
      {
        name = "security";
        type = "vlogs";
        interval = "1m";
        rules = [
          {
            alert = "SSHBruteForce";
            expr = ''unit:"sshd.service" AND (_msg:"Failed password" OR _msg:"authentication failure" OR _msg:"Invalid user" OR _msg:"Connection closed by authenticating user") | stats by (host) count() as failures | filter failures:>10'';
            "for" = "0m";
            labels = {
              severity = "warning";
              category = "security";
            };
            annotations.summary = "{{ $labels.host }}: more than 10 SSH auth failures in 5 minutes";
          }
          {
            alert = "SSHBruteForceExtreme";
            expr = ''unit:"sshd.service" AND (_msg:"Failed password" OR _msg:"authentication failure" OR _msg:"Invalid user" OR _msg:"Connection closed by authenticating user") | stats by (host) count() as failures | filter failures:>50'';
            "for" = "0m";
            labels = {
              severity = "critical";
              category = "security";
            };
            annotations.summary = "{{ $labels.host }}: more than 50 SSH auth failures in 5 minutes — active brute force";
          }
          {
            alert = "SudoFailure";
            expr = ''comm:"sudo" AND (_msg:"authentication failure" OR _msg:"incorrect password") | stats by (host) count() as failures | filter failures:>0'';
            "for" = "0m";
            labels = {
              severity = "warning";
              category = "security";
            };
            annotations.summary = "{{ $labels.host }}: failed sudo authentication attempt";
          }
          {
            alert = "HighPriorityLogs";
            expr = ''priority:in("0","1","2") | stats by (host) count() as critical_logs | filter critical_logs:>0'';
            "for" = "0m";
            labels = {
              severity = "critical";
              category = "security";
            };
            annotations.summary = "{{ $labels.host }}: emergency/alert/critical log messages detected";
          }
        ];
      }
      {
        name = "log-health";
        type = "vlogs";
        interval = "1m";
        rules = [
          {
            alert = "FleetLogGap";
            expr = ''job:"systemd-journal" | stats by (host) count() as lines | stats count() as hosts | filter hosts:<${toString expectedHosts}'';
            "for" = "15m";
            labels.severity = "warning";
            annotations.summary = "Fewer than ${toString expectedHosts} hosts shipping logs to VictoriaLogs";
          }
        ];
      }
    ];
  });
in {
  services.victorialogs = {
    enable = true;
    listenAddress = "127.0.0.1:${toString vlPort}";
    extraOptions = [
      "-retentionPeriod=30d"
    ];
  };

  systemd.services.vmalert-vlogs = {
    description = "vmalert (VictoriaLogs rules)";
    wantedBy = ["multi-user.target"];
    after = ["network.target" "victorialogs.service"];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.victoriametrics}/bin/vmalert"
        "-datasource.url=http://127.0.0.1:${toString vlPort}"
        "-notifier.url=http://127.0.0.1:9093"
        "-rule.defaultRuleType=vlogs"
        "-rule=${securityRules}"
        "-httpListenAddr=127.0.0.1:${toString vlAlertPort}"
      ];
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/victorialogs";
      user = "victorialogs";
      group = "victorialogs";
      mode = "0700";
    }
  ];
}
