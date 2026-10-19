{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.router6;
  r6lib = import ./lib.nix {inherit cfg lib;};
  socketRetrySettings = {
    # Give slow VLAN/bridge setup five minutes, then exit rather than remain
    # active without sockets. systemd restarts Kea for another attempt.
    service-sockets-require-all = true;
    service-sockets-max-retries = 150;
    service-sockets-retry-wait-time = 2000;
  };
  keaStartup = family: interfaces: {
    after = ["systemd-networkd.service"];
    wants = ["systemd-networkd.service"];
    startLimitIntervalSec = 0;
    serviceConfig = {
      # Global wait-online is deliberately disabled on routers. Wait only for
      # this server's LAN interfaces and address family, independently of WAN.
      ExecStartPre = [
        (utils.escapeSystemdExecArgs (
          ["${pkgs.systemd}/lib/systemd/systemd-networkd-wait-online" "--timeout=60" "--ipv${family}"]
          ++ map (iface: "--interface=${iface}:degraded") interfaces
        ))
      ];
      TimeoutStartSec = 90;
      # Kea can terminate cleanly after asynchronous socket retry exhaustion.
      Restart = lib.mkForce "always";
      RestartSec = 5;
    };
  };
in {
  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Kea DHCP4 Server
    (lib.mkIf (r6lib.keaSubnets != []) {
      systemd.services.kea-dhcp4-server = keaStartup "4" r6lib.dhcpServerInterfaces;
      services.kea.dhcp4 = {
        enable = true;
        settings = {
          interfaces-config =
            socketRetrySettings
            // {
              interfaces = r6lib.dhcpServerInterfaces;
              dhcp-socket-type = "raw";
            };

          lease-database = {
            type = "memfile";
            persist = true;
            name = "/var/lib/kea/dhcp4.leases";
          };

          valid-lifetime = 7200;
          renew-timer = 1800;
          rebind-timer = 3600;

          subnet4 = r6lib.keaSubnets;

          ddns-send-updates = false;

          option-def = [];

          loggers = [
            {
              name = "kea-dhcp4";
              output_options = [{output = "syslog";}];
              severity = "INFO";
            }
          ];
        };
      };
    })

    # Kea DHCP6 Server
    (lib.mkIf (r6lib.keaSubnets6 != []) {
      systemd.services.kea-dhcp6-server = keaStartup "6" r6lib.dhcp6ServerInterfaces;
      services.kea.dhcp6 = {
        enable = true;
        settings = {
          interfaces-config =
            socketRetrySettings
            // {
              interfaces = r6lib.dhcp6ServerInterfaces;
            };

          lease-database = {
            type = "memfile";
            persist = true;
            name = "/var/lib/kea/dhcp6.leases";
          };

          preferred-lifetime = 3600;
          valid-lifetime = 7200;
          renew-timer = 1800;
          rebind-timer = 3600;

          subnet6 = r6lib.keaSubnets6;

          loggers = [
            {
              name = "kea-dhcp6";
              output_options = [{output = "syslog";}];
              severity = "INFO";
            }
          ];
        };
      };
    })
  ]);
}
