{ config, pkgs, lib, ... }:

{
  # Enable Incus instance management with auto-updates
  incus-manager = {
    enable = true;
    flakePath = "/persist/dotfiles";

    # Storage configuration
    storage = {
      driver = "zfs";
      pool = "default";
      source = "persist/incus";  # ZFS dataset for Incus storage
    };

    # Network configuration
    networks = {
      # Use existing bridge br20 for container network (VLAN 20 - trusted)
      incusbr20 = {
        type = "bridge";
        bridge = "br20";
        ipv4 = null;
        ipv6 = null;
        nat = false;
      };

      # Use existing bridge br100 for DMZ VMs (VLAN 100)
      incusbr100 = {
        type = "bridge";
        bridge = "br100";
        ipv4 = null;
        ipv6 = null;
        nat = false;
      };
    };

    # Profiles
    profiles = {
      # Profile for development containers (trusted VLAN)
      dev = {
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
      };
    };

    # VM definitions
    virtualMachines = {
      # messeldam — Dev environment / task runner (VLAN 20, trusted)
      messeldam = {
        autoUpdate = true;
        profile = "dev";
        network = "incusbr20";
        autoStart = true;
      };
    };
  };
}
