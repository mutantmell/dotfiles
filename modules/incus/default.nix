{ config, options, pkgs, lib, ... }:

# Incus Container Management Module
#
# Provides declarative management of Incus containers with automatic in-place updates.
# Containers are updated via `nixos-rebuild switch` inside the container when the
# host configuration changes, minimizing disruption to running processes.
#
# Design principles:
# - Image/instance separation (images are templates, instances are persistent)
# - Auto-update on host rebuild (configurable per container)
# - Minimal disruption (only changed services restart)
# - Fully declarative container definitions

let
  cfg = config.incus-manager;

  inherit (lib) mkOption mkEnableOption types mkIf mkMerge optional optionals
    mapAttrs mapAttrsToList filterAttrs concatMapAttrs optionalAttrs optionalString
    concatStringsSep flatten filter elem literalExpression;
  inherit (builtins) attrNames attrValues hasAttr length toString;

  # Helper to build container update script
  mkUpdateScript = name: containerCfg: pkgs.writeShellScript "update-incus-container-${name}" ''
    set -e

    CONTAINER="${name}"
    FLAKE_REF="${containerCfg.flakeRef}"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Updating container: $CONTAINER"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check if container exists
    if ! ${pkgs.incus}/bin/incus list --format=csv -c n | grep -q "^$CONTAINER$"; then
      echo "  ⚠ Container $CONTAINER does not exist (will be created on first launch)"
      exit 0
    fi

    # Check if container is running
    if ! ${pkgs.incus}/bin/incus list --format=csv -c ns | grep -q "^$CONTAINER,RUNNING"; then
      echo "  ⚠ Container $CONTAINER is not running (skipping update)"
      exit 0
    fi

    # Run nixos-rebuild switch inside container
    echo "  Running nixos-rebuild switch in container..."
    if ${pkgs.incus}/bin/incus exec "$CONTAINER" -- \
      nixos-rebuild switch --flake "$FLAKE_REF" 2>&1 | sed 's/^/    /'; then
      echo "  ✓ Container $CONTAINER updated successfully"
    else
      echo "  ✗ Failed to update container $CONTAINER"
      exit 1
    fi
  '';

  # Build script to update all managed containers
  updateAllScript = pkgs.writeShellScript "update-all-incus-containers" ''
    set -e

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Updating Incus containers..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    ${concatStringsSep "\n    " (mapAttrsToList (name: containerCfg:
      if containerCfg.autoUpdate then
        "${mkUpdateScript name containerCfg} || echo '  ⚠ Failed to update ${name}, continuing...'"
      else
        "echo 'Skipping ${name} (autoUpdate disabled)'"
    ) cfg.containers)}

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ Container update process complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  '';

in {
  options.incus-manager = {
    enable = mkEnableOption "Incus container management with auto-updates";

    flakeUrl = mkOption {
      type = types.str;
      default = "git+file:///etc/nixos";
      description = ''
        Default flake URL for container configurations.
        Can be overridden per-container.
      '';
      example = "github:user/dotfiles";
    };

    storage = mkOption {
      type = types.submodule {
        options = {
          driver = mkOption {
            type = types.enum ["zfs" "dir" "btrfs" "lvm"];
            default = "zfs";
            description = "Storage driver for Incus";
          };

          pool = mkOption {
            type = types.str;
            default = "default";
            description = "Name of the storage pool";
          };

          source = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Source for storage (e.g., ZFS dataset path)";
            example = "tank/incus";
          };
        };
      };
      default = {};
    };

    networks = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          type = mkOption {
            type = types.enum ["bridge"];
            default = "bridge";
            description = "Network type";
          };

          bridge = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Existing bridge to use. When set, Incus will attach to this
              external bridge instead of managing its own.
            '';
            example = "br20";
          };

          ipv4 = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "IPv4 address/CIDR for bridge (none if using external bridge)";
            example = "10.0.20.1/24";
          };

          ipv6 = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "IPv6 address/CIDR for bridge (none if using external bridge)";
          };

          nat = mkOption {
            type = types.bool;
            default = false;
            description = "Enable NAT for this network";
          };
        };
      });
      default = {};
      description = "Network configurations for Incus";
    };

    profiles = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          description = mkOption {
            type = types.str;
            default = "";
          };

          config = mkOption {
            type = types.attrs;
            default = {};
            description = "Profile configuration (limits, security, etc.)";
            example = literalExpression ''
              {
                "limits.cpu" = "4";
                "limits.memory" = "8GB";
                "security.nesting" = "true";
              }
            '';
          };

          devices = mkOption {
            type = types.attrs;
            default = {};
            description = "Device configuration for profile";
            example = literalExpression ''
              {
                root = {
                  path = "/";
                  pool = "default";
                  type = "disk";
                  size = "100GB";
                };
                eth0 = {
                  name = "eth0";
                  network = "incusbr20";
                  type = "nic";
                };
              }
            '';
          };
        };
      });
      default = {};
      description = "Incus profiles";
    };

    containers = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          image = mkOption {
            type = types.str;
            description = ''
              Container image reference. This should match a nixosConfiguration
              output in your flake that builds a container image.
            '';
            example = "devbox-image";
          };

          autoUpdate = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Automatically update container when host rebuilds.
              When enabled, runs nixos-rebuild switch inside the container
              during host activation.
            '';
          };

          flakeRef = mkOption {
            type = types.str;
            default = "${cfg.flakeUrl}#${name}";
            description = ''
              Flake reference for this container's configuration.
              Used by nixos-rebuild inside the container.
            '';
            example = "github:user/dotfiles#container-name";
          };

          profile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Incus profile to apply to this container";
            example = "dev";
          };

          network = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Network to connect to";
            example = "incusbr20";
          };

          autoStart = mkOption {
            type = types.bool;
            default = true;
            description = "Auto-start container on boot";
          };
        };
      }));
      default = {};
      description = ''
        Declarative container definitions.
        Note: Containers must be created manually with `incus launch`.
        This module manages their configuration and updates.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Enable Incus
    virtualisation.incus = {
      enable = true;

      preseed = {
        # Storage pools
        storage_pools = [{
          name = cfg.storage.pool;
          driver = cfg.storage.driver;
          config = optionalAttrs (cfg.storage.source != null) {
            source = cfg.storage.source;
          };
        }];

        # Networks
        networks = mapAttrsToList (name: netCfg: {
          inherit name;
          type = netCfg.type;
          config =
            optionalAttrs (netCfg.bridge != null) {
              "bridge.external_interfaces" = netCfg.bridge;
            }
            // optionalAttrs (netCfg.ipv4 != null) {
              "ipv4.address" = netCfg.ipv4;
              "ipv4.nat" = if netCfg.nat then "true" else "false";
            }
            // optionalAttrs (netCfg.ipv4 == null && netCfg.bridge != null) {
              "ipv4.address" = "none";
            }
            // optionalAttrs (netCfg.ipv6 != null) {
              "ipv6.address" = netCfg.ipv6;
              "ipv6.nat" = if netCfg.nat then "true" else "false";
            }
            // optionalAttrs (netCfg.ipv6 == null) {
              "ipv6.address" = "none";
            };
        }) cfg.networks;

        # Profiles
        profiles = mapAttrsToList (name: profileCfg: {
          inherit name;
          description = profileCfg.description;
          config = profileCfg.config;
          devices = profileCfg.devices;
        }) cfg.profiles;
      };
    };

    # Auto-update containers on system activation
    # This runs in the background to avoid blocking activation
    system.activationScripts.updateIncusContainers = lib.mkIf (cfg.containers != {}) {
      text = ''
        # Launch container updates in background
        (${updateAllScript} &) || true
      '';
      deps = [];
    };

    # Systemd service for manual container updates
    systemd.services.incus-container-updates = {
      description = "Update Incus containers in-place";
      after = [ "incus.service" ];
      requires = [ "incus.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = updateAllScript;
        # Don't fail if some containers can't be updated
        SuccessExitStatus = "0 1";
      };

      # Not wanted by any target (triggered manually or by activation script)
      wantedBy = [];
    };

    # Helper script for manual updates
    environment.systemPackages = [
      (pkgs.writeScriptBin "incus-update-containers" ''
        #!${pkgs.bash}/bin/bash
        exec ${pkgs.systemd}/bin/systemctl start incus-container-updates.service
      '')
      (pkgs.writeScriptBin "incus-update-container" ''
        #!${pkgs.bash}/bin/bash
        if [ $# -ne 1 ]; then
          echo "Usage: incus-update-container <container-name>"
          exit 1
        fi

        CONTAINER="$1"

        # Check if container is managed
        case "$CONTAINER" in
          ${concatStringsSep "\n          " (mapAttrsToList (name: _: "${name})") cfg.containers)}
            ${concatStringsSep "\n            " (mapAttrsToList (name: containerCfg:
              "[ \"$CONTAINER\" = \"${name}\" ] && exec ${mkUpdateScript name containerCfg}"
            ) cfg.containers)}
            ;;
          *)
            echo "Error: Container '$CONTAINER' is not managed by incus-manager"
            echo "Managed containers: ${concatStringsSep ", " (attrNames cfg.containers)}"
            exit 1
            ;;
        esac
      '')
    ];

    # Add user to incus-admin group
    users.groups.incus-admin = {};
  };
}
