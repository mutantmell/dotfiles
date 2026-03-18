_: {
  common.incus = {
    enable = true;
    guestDir = ./guests;
  };

  # Preseed via NixOS built-in — storage pool and profiles
  virtualisation.incus.preseed = {
    storage_pools = [
      {
        name = "default";
        driver = "btrfs";
        config.source = "/persist/incus";
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
      {
        name = "dmz-vm";
        description = "DMZ virtual machine profile";
        config = {
          "limits.cpu" = "4";
          "limits.memory" = "4GB";
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
