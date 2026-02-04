{ config, options, pkgs, lib, ... }:

# Incus Container Management Module
#
# Provides declarative management of Incus containers with automatic in-place updates.
# Containers are updated via `nixos-rebuild switch` inside the container when the
# host configuration changes, minimizing disruption to running processes.
#
# Design principles:
# - Fully declarative (instances auto-created on activation)
# - Image/instance separation (images are templates, instances are persistent)
# - Auto-update on host rebuild (configurable per-container)
# - Minimal disruption (only changed services restart)

let
  cfg = config.incus-manager;

  inherit (lib) mkOption mkEnableOption types mkIf mkMerge optional optionals
    mapAttrs mapAttrsToList filterAttrs concatMapAttrs optionalAttrs optionalString
    concatStringsSep flatten filter elem literalExpression nixosSystem;
  inherit (builtins) attrNames attrValues hasAttr length toString;

  # Helper to build container image from NixOS configuration
  mkContainerImage = name: containerSystem: pkgs.runCommand "${name}-image" {} ''
    mkdir -p $out
    ln -s ${containerSystem.config.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
    ln -s ${containerSystem.config.system.build.tarball}/tarball/*.tar.xz $out/rootfs.tar.xz
  '';

  # Helper to build instance creation/update script
  mkInstanceScript = name: containerCfg: pkgs.writeShellScript "incus-ensure-${name}" ''
    set -e

    CONTAINER="${name}"
    IMAGE_ALIAS="${containerCfg.image}"
    PROFILE="${optionalString (containerCfg.profile != null) containerCfg.profile}"
    NETWORK="${optionalString (containerCfg.network != null) containerCfg.network}"

    # Import image if it doesn't exist
    if ! ${pkgs.incus}/bin/incus image list --format=csv -c l | grep -q "^$IMAGE_ALIAS$"; then
      echo "  Importing image: $IMAGE_ALIAS"
      ${pkgs.incus}/bin/incus image import \
        ${containerCfg.imagePackage}/metadata.tar.xz \
        ${containerCfg.imagePackage}/rootfs.tar.xz \
        --alias "$IMAGE_ALIAS"
    fi

    # Create instance if it doesn't exist
    if ! ${pkgs.incus}/bin/incus list --format=csv -c n | grep -q "^$CONTAINER$"; then
      echo "  Creating instance: $CONTAINER"
      ${pkgs.incus}/bin/incus init "$IMAGE_ALIAS" "$CONTAINER" \
        ${optionalString (containerCfg.profile != null) "--profile ${containerCfg.profile}"}

      ${optionalString (containerCfg.network != null) ''
      # Add network device if specified
      ${pkgs.incus}/bin/incus config device add "$CONTAINER" eth0 nic \
        network="${containerCfg.network}" \
        name=eth0 || true
      ''}
    fi

    # Start instance if autoStart is enabled and not running
    ${optionalString containerCfg.autoStart ''
    if ! ${pkgs.incus}/bin/incus list --format=csv -c ns | grep -q "^$CONTAINER,RUNNING"; then
      echo "  Starting instance: $CONTAINER"
      ${pkgs.incus}/bin/incus start "$CONTAINER"
    fi
    ''}
  '';

  # Helper to build container update script
  mkUpdateScript = name: containerCfg: pkgs.writeShellScript "update-incus-container-${name}" ''
    set -e

    CONTAINER="${name}"

    # Check if container exists
    if ! ${pkgs.incus}/bin/incus list --format=csv -c n | grep -q "^$CONTAINER$"; then
      echo "  ⚠ Container $CONTAINER does not exist (skipping update)"
      exit 0
    fi

    # Check if container is running
    if ! ${pkgs.incus}/bin/incus list --format=csv -c ns | grep -q "^$CONTAINER,RUNNING"; then
      echo "  ⚠ Container $CONTAINER is not running (skipping update)"
      exit 0
    fi

    # Run nixos-rebuild switch inside container
    echo "  Updating container: $CONTAINER"
    if ${pkgs.incus}/bin/incus exec "$CONTAINER" -- \
      nixos-rebuild switch 2>&1 | sed 's/^/    /'; then
      echo "  ✓ Container $CONTAINER updated successfully"
    else
      echo "  ✗ Failed to update container $CONTAINER"
      exit 1
    fi
  '';

  # Script to ensure all instances exist
  ensureInstancesScript = pkgs.writeShellScript "incus-ensure-instances" ''
    set -e

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Ensuring Incus instances exist..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    ${concatStringsSep "\n    " (mapAttrsToList (name: containerCfg:
      "${mkInstanceScript name containerCfg} || echo '  ⚠ Failed to ensure ${name}, continuing...'"
    ) cfg.containers)}

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✓ Instance check complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
              }
            '';
          };
        };
      });
      default = {};
      description = "Incus profiles";
    };

    containers = mkOption {
      type = types.attrsOf (types.submodule ({ name, config, ... }: {
        options = {
          configurationFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              Path to NixOS configuration file for this container.
              When set, the container image will be built automatically.
              Mutually exclusive with setting imagePackage explicitly.
            '';
            example = literalExpression "./containers/surtr/configuration.nix";
          };

          image = mkOption {
            type = types.str;
            default = name;
            description = ''
              Image alias to use for this container.
              Defaults to the container name.
            '';
            example = "surtr";
          };

          imagePackage = mkOption {
            type = types.package;
            default =
              if config.configurationFile != null
              then mkContainerImage name (nixosSystem {
                system = "x86_64-linux";
                modules = [
                  config.configurationFile
                  "${pkgs.path}/nixos/modules/virtualisation/lxc-container.nix"
                ];
              })
              else throw "Container ${name}: Either configurationFile or imagePackage must be set";
            defaultText = literalExpression "Built from configurationFile";
            description = ''
              Package containing the container image (metadata.tar.xz and rootfs.tar.xz).
              Can be provided directly or built automatically from configurationFile.
            '';
            example = literalExpression "pkgs.mmell.surtr-image";
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
        Containers are automatically created, started, and updated.
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

    # nftables is required for incus
    networking.nftables.enable = true;

    # Ensure instances exist and are started on system activation
    system.activationScripts.incusEnsureInstances = lib.mkIf (cfg.containers != {}) {
      text = ''
        # Ensure all instances exist and are started
        ${ensureInstancesScript}
      '';
    };

    # Auto-update containers on system activation
    # This runs in the background to avoid blocking activation
    system.activationScripts.updateIncusContainers = lib.mkIf (cfg.containers != {}) {
      text = ''
        # Launch container updates in background
        (${updateAllScript} &) || true
      '';
      deps = [ "incusEnsureInstances" ];
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
      (pkgs.writeScriptBin "incus-ensure-instances" ''
        #!${pkgs.bash}/bin/bash
        exec ${ensureInstancesScript}
      '')
    ];

    # Add user to incus-admin group
    users.groups.incus-admin = {};
  };
}
