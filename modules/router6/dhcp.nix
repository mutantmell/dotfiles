{
  config,
  lib,
  ...
}: let
  cfg = config.router6;
  r6lib = import ./lib.nix {inherit cfg lib;};
in {
  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Kea DHCP4 Server
    (lib.mkIf (r6lib.keaSubnets != []) {
      services.kea.dhcp4 = {
        enable = true;
        settings = {
          interfaces-config = {
            interfaces = r6lib.dhcpServerInterfaces;
            dhcp-socket-type = "raw";
            service-sockets-max-retries = 10;
            service-sockets-retry-wait-time = 2000;
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
      services.kea.dhcp6 = {
        enable = true;
        settings = {
          interfaces-config = {
            interfaces = r6lib.dhcp6ServerInterfaces;
            service-sockets-max-retries = 10;
            service-sockets-retry-wait-time = 2000;
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
