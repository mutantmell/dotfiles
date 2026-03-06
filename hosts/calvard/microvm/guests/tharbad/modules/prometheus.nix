{ config, ... }:
{
  networking.firewall.allowedTCPPorts = [
    config.services.prometheus.port
  ];

  services.prometheus = {
    enable = true;
    port = 9090;
    exporters.node = {
      enable = true;
      enabledCollectors = [ "systemd" ];
      port = 9100;
    };
    scrapeConfigs = [
      {
        job_name = "ymir_node";
        static_configs = [{
          targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
        }];
      }
      {
        job_name = "thebeyond_node";
        static_configs = [{
          targets = [ "thebeyond.internal:9100" ];
        }];
      }
      {
        job_name = "erebonia_node";
        static_configs = [{
          targets = [ "erebonia.internal:9100" ];
        }];
      }
      {
        job_name = "calvard_node";
        static_configs = [{
          targets = [ "calvard.internal:9100" ];
        }];
      }
      {
        job_name = "remiferia_node";
        static_configs = [{
          targets = [ "remiferia.internal:9001" ];
        }];
      }
      {
        job_name = "remiferia_zfs";
        static_configs = [{
          targets = [ "remiferia.internal:9002" ];
        }];
      }
      {
        job_name = "remiferia_smartctl";
        static_configs = [{
          targets = [ "remiferia.internal:9003" ];
        }];
      }
    ];
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/" + config.services.prometheus.stateDir;
      user = "prometheus";
      group = config.users.users.prometheus.group;
    }
  ];
}
