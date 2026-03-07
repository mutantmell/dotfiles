{
  config,
  pkgs,
  lib,
  ...
}: {
  common.incus = {
    enable = true;
    guestDir = ./guests;
  };

  # Preseed via NixOS built-in — storage, networks, profiles
  virtualisation.incus.preseed = {
    storage_pools = [
      {
        name = "default";
        driver = "zfs";
        config.source = "persist/incus";
      }
    ];

    networks = [
      {
        name = "incusbr20";
        type = "bridge";
        config = {
          "bridge.external_interfaces" = "br20";
          "ipv4.address" = "none";
          "ipv6.address" = "none";
        };
      }
      {
        name = "incusbr100";
        type = "bridge";
        config = {
          "bridge.external_interfaces" = "br100";
          "ipv4.address" = "none";
          "ipv6.address" = "none";
        };
      }
    ];

    profiles = [
      {
        name = "dev";
        description = "Development VM profile";
        config = {
          "limits.cpu" = "4";
          "limits.memory" = "4GB";
          "security.privileged" = "false";
        };
        devices = {
          root = {
            path = "/";
            pool = "default";
            type = "disk";
            size = "50GB";
          };
        };
      }
    ];
  };
}
