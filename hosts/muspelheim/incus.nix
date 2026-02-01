{ config, pkgs, lib, ... }:

{
  # Enable Incus container management with auto-updates
  incus-manager = {
    enable = true;

    # Flake URL for container configurations
    flakeUrl = "git+file:///etc/nixos";  # Local flake
    # Or use: flakeUrl = "github:mutantmell/dotfiles";  # Remote flake

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

          # Network interface
          eth0 = {
            name = "eth0";
            network = "incusbr20";
            type = "nic";
          };
        };
      };
    };

    # Container definitions
    containers = {
      # surtr container (migrated from microVM)
      surtr = {
        image = "surtr-image";
        autoUpdate = true;
        profile = "dev";
        network = "incusbr20";
        autoStart = true;

        # Flake reference for this container's nixos configuration
        # This is what gets passed to `nixos-rebuild switch` inside the container
        flakeRef = "git+file:///etc/nixos#surtr-image";
        # Or remote: flakeRef = "github:mutantmell/dotfiles#surtr-image";
      };
    };
  };

  # Add user to incus-admin group for container management
  # users.users.youruser.extraGroups = [ "incus-admin" ];
}
