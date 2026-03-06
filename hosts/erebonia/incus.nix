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
      # Use existing bridge br20 for VM network (VLAN 20 - trusted)
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
      # Profile for development VMs
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

      # Profile for DMZ virtual machines
      dmz-vm = {
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
      };
    };

    # Virtual machine definitions
    virtualMachines = {
      # trista — Dev environment / task runner (VLAN 100, DMZ)
      trista = {
        autoUpdate = true;
        profile = "dmz-vm";
        network = "incusbr100";
        autoStart = true;
      };
    };
  };

  # Add user to incus-admin group for instance management
  # users.users.youruser.extraGroups = [ "incus-admin" ];
}
