{ config, pkgs, lib, ... }:

{
  # Enable Incus container management with auto-updates
  incus-manager = {
    enable = true;

    # Storage configuration
    storage = {
      driver = "zfs";
      pool = "default";
      source = "persist/incus";  # ZFS dataset for Incus storage
    };

    # Network configuration
    # Use existing bridge br20 for container network (VLAN 20 - trusted)
    networks = {
      incusbr20 = {
        type = "bridge";
        bridge = "br20";  # Use existing bridge
        # No IP configuration needed (bridge already configured)
        ipv4 = null;
        ipv6 = null;
        nat = false;
      };
    };

    # Profiles for containers
    profiles = {
      # Default profile for development containers
      dev = {
        description = "Development container profile";
        config = {
          # Resource limits
          "limits.cpu" = "4";
          "limits.memory" = "4GB";

          # Security settings
          "security.privileged" = "false";  # Unprivileged containers
          "security.nesting" = "true";      # Allow nested containers/docker if needed
        };
        devices = {
          # Root disk
          root = {
            path = "/";
            pool = "default";
            type = "disk";
            size = "50GB";
          };
        };
      };
    };

    # Container definitions
    containers = {
      # ordis container (migrated from microVM)
      ordis = {
        configurationFile = ./containers/ordis;
        autoUpdate = true;
        profile = "dev";
        network = "incusbr20";
        autoStart = true;
      };
    };
  };

  # Add user to incus-admin group for container management
  # users.users.youruser.extraGroups = [ "incus-admin" ];
}
