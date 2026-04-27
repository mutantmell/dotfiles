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
          webhook_configs = [{url = "http://localhost:2586/infra-critical?template=alertmanager";}];
        }
        {
          name = "ntfy-security";
          webhook_configs = [{url = "http://localhost:2586/security?template=alertmanager";}];
        }
        {
          name = "ntfy-cicd";
          webhook_configs = [{url = "http://localhost:2586/cicd?template=alertmanager";}];
        }
        {
          name = "ntfy-default";
          webhook_configs = [{url = "http://localhost:2586/services?template=alertmanager";}];
        }
      ];
    };
  };

  # Alert rules and alertmanager wiring have moved to victoriametrics.nix (vmalert).
  # Prometheus has no rules or notifier config after this migration.

  environment.persistence."/persist".directories = [
    "/var/lib/private/alertmanager"
  ];
}
