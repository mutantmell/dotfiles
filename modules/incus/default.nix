{ config, options, pkgs, lib, ... }:

# Incus Instance Management Module
#
# Provides declarative management of Incus containers and virtual machines
# with automatic in-place updates. Instances are updated via `nixos-rebuild switch`
# inside the instance when the host configuration changes, minimizing disruption
# to running processes.
#
# Design principles:
# - Fully declarative (instances auto-created on activation)
# - Image/instance separation (images are templates, instances are persistent)
# - Auto-update on host rebuild (configurable per-instance)
# - Minimal disruption (only changed services restart)

let
  cfg = config.incus-manager;

  inherit (lib) mkOption mkEnableOption types mkIf mkMerge optional optionals
    mapAttrs mapAttrsToList filterAttrs concatMapAttrs optionalAttrs optionalString
    concatStringsSep flatten filter elem literalExpression nixosSystem;
  inherit (builtins) attrNames attrValues hasAttr length toString;

  hasInstances = cfg.containers != {} || cfg.virtualMachines != {};

  # Shared instance option definitions (used by both containers and VMs)
  instanceOptions = { name, config, ... }: {
    options = {
      configurationFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to NixOS configuration file for this instance.
          When set, the instance image will be built automatically.
          Mutually exclusive with setting imagePackage explicitly.
        '';
      };

      image = mkOption {
        type = types.str;
        default = name;
        description = ''
          Image alias to use for this instance.
          Defaults to the instance name.
        '';
      };

      imagePackage = mkOption {
        type = types.package;
        description = ''
          Package containing the instance image.
          Can be provided directly or built automatically from configurationFile.
        '';
      };

      autoUpdate = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Automatically update instance when host rebuilds.
          When enabled, runs nixos-rebuild switch inside the instance
          during host activation.
        '';
      };

      profile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Incus profile to apply to this instance";
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
        description = "Auto-start instance on boot";
      };
    };
  };

  # Helper to build container image from NixOS configuration
  mkContainerImage = name: containerSystem: pkgs.runCommand "${name}-image" {} ''
    mkdir -p $out
    ln -s ${containerSystem.config.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
    ln -s ${containerSystem.config.system.build.tarball}/tarball/*.tar.xz $out/rootfs.tar.xz
  '';

  # Helper to build VM image from NixOS configuration
  mkVMImage = name: vmSystem: pkgs.runCommand "${name}-vm-image" {} ''
    mkdir -p $out
    ln -s ${vmSystem.config.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
    ln -s ${vmSystem.config.system.build.qemuImage}/*.qcow2 $out/disk.qcow2
  '';

  # Helper to build container instance creation script
  mkContainerInstanceScript = name: containerCfg: pkgs.writeShellScript "incus-ensure-${name}" ''
    set -e

    INSTANCE="${name}"
    IMAGE_ALIAS="${containerCfg.image}"

    # Import image if it doesn't exist
    if ! ${pkgs.incus}/bin/incus image list --format=csv -c l | grep -q "^$IMAGE_ALIAS$"; then
      echo "  Importing image: $IMAGE_ALIAS"
      ${pkgs.incus}/bin/incus image import \
        ${containerCfg.imagePackage}/metadata.tar.xz \
        ${containerCfg.imagePackage}/rootfs.tar.xz \
        --alias "$IMAGE_ALIAS"
    fi

    # Create instance if it doesn't exist
    if ! ${pkgs.incus}/bin/incus list --format=csv -c n | grep -q "^$INSTANCE$"; then
      echo "  Creating container: $INSTANCE"
      ${pkgs.incus}/bin/incus init "$IMAGE_ALIAS" "$INSTANCE" \
        ${optionalString (containerCfg.profile != null) "--profile ${containerCfg.profile}"}

      ${optionalString (containerCfg.network != null) ''
      # Add network device if specified
      ${pkgs.incus}/bin/incus config device add "$INSTANCE" eth0 nic \
        network="${containerCfg.network}" \
        name=eth0 || true
      ''}
    fi

    # Start instance if autoStart is enabled and not running
    ${optionalString containerCfg.autoStart ''
    if ! ${pkgs.incus}/bin/incus list --format=csv -c ns | grep -q "^$INSTANCE,RUNNING"; then
      echo "  Starting container: $INSTANCE"
      ${pkgs.incus}/bin/incus start "$INSTANCE"
    fi
    ''}
  '';

  # Helper to build VM instance creation script
  mkVMInstanceScript = name: vmCfg: pkgs.writeShellScript "incus-ensure-vm-${name}" ''
    set -e

    INSTANCE="${name}"
    IMAGE_ALIAS="${vmCfg.image}"

    # Import VM image if it doesn't exist
    if ! ${pkgs.incus}/bin/incus image list --format=csv -c l | grep -q "^$IMAGE_ALIAS$"; then
      echo "  Importing VM image: $IMAGE_ALIAS"
      ${pkgs.incus}/bin/incus image import \
        ${vmCfg.imagePackage}/metadata.tar.xz \
        ${vmCfg.imagePackage}/disk.qcow2 \
        --alias "$IMAGE_ALIAS"
    fi

    # Create VM instance if it doesn't exist
    if ! ${pkgs.incus}/bin/incus list --format=csv -c n | grep -q "^$INSTANCE$"; then
      echo "  Creating VM: $INSTANCE"
      ${pkgs.incus}/bin/incus init "$IMAGE_ALIAS" "$INSTANCE" --vm \
        ${optionalString (vmCfg.profile != null) "--profile ${vmCfg.profile}"}

      ${optionalString (vmCfg.network != null) ''
      # Add network device if specified
      ${pkgs.incus}/bin/incus config device add "$INSTANCE" eth0 nic \
        network="${vmCfg.network}" \
        name=eth0 || true
      ''}
    fi

    # Start VM if autoStart is enabled and not running
    ${optionalString vmCfg.autoStart ''
    if ! ${pkgs.incus}/bin/incus list --format=csv -c ns | grep -q "^$INSTANCE,RUNNING"; then
      echo "  Starting VM: $INSTANCE"
      ${pkgs.incus}/bin/incus start "$INSTANCE"
    fi
    ''}
  '';

  # Helper to build instance update script (works for both containers and VMs)
  mkUpdateScript = name: instanceCfg: pkgs.writeShellScript "update-incus-instance-${name}" ''
    set -e

    INSTANCE="${name}"

    # Check if instance exists
    if ! ${pkgs.incus}/bin/incus list --format=csv -c n | grep -q "^$INSTANCE$"; then
      echo "  Warning: Instance $INSTANCE does not exist (skipping update)"
      exit 0
    fi

    # Check if instance is running
    if ! ${pkgs.incus}/bin/incus list --format=csv -c ns | grep -q "^$INSTANCE,RUNNING"; then
      echo "  Warning: Instance $INSTANCE is not running (skipping update)"
      exit 0
    fi

    # Run nixos-rebuild switch inside instance
    echo "  Updating instance: $INSTANCE"
    if ${pkgs.incus}/bin/incus exec "$INSTANCE" -- \
      nixos-rebuild switch 2>&1 | sed 's/^/    /'; then
      echo "  Done: Instance $INSTANCE updated successfully"
    else
      echo "  Error: Failed to update instance $INSTANCE"
      exit 1
    fi
  '';

  # All instances (containers + VMs) for update scripts
  allInstances = cfg.containers // cfg.virtualMachines;

  # Script to ensure all instances exist
  ensureInstancesScript = pkgs.writeShellScript "incus-ensure-instances" ''
    set -e

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Ensuring Incus instances exist..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    ${concatStringsSep "\n    " (mapAttrsToList (name: containerCfg:
      "${mkContainerInstanceScript name containerCfg} || echo '  Warning: Failed to ensure container ${name}, continuing...'"
    ) cfg.containers)}

    ${concatStringsSep "\n    " (mapAttrsToList (name: vmCfg:
      "${mkVMInstanceScript name vmCfg} || echo '  Warning: Failed to ensure VM ${name}, continuing...'"
    ) cfg.virtualMachines)}

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Done: Instance check complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  '';

  # Build script to update all managed instances
  updateAllScript = pkgs.writeShellScript "update-all-incus-instances" ''
    set -e

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Updating Incus instances..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    ${concatStringsSep "\n    " (mapAttrsToList (name: instanceCfg:
      if instanceCfg.autoUpdate then
        "${mkUpdateScript name instanceCfg} || echo '  Warning: Failed to update ${name}, continuing...'"
      else
        "echo 'Skipping ${name} (autoUpdate disabled)'"
    ) allInstances)}

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Done: Instance update process complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  '';

in {
  options.incus-manager = {
    enable = mkEnableOption "Incus instance management with auto-updates";

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
        imports = [ instanceOptions ];
        config.imagePackage = lib.mkDefault (
          if config.configurationFile != null
          then mkContainerImage name (nixosSystem {
            system = "x86_64-linux";
            modules = [
              config.configurationFile
              "${pkgs.path}/nixos/modules/virtualisation/lxc-container.nix"
            ];
          })
          else throw "Container ${name}: Either configurationFile or imagePackage must be set"
        );
      }));
      default = {};
      description = ''
        Declarative container definitions.
        Containers are automatically created, started, and updated.
      '';
    };

    virtualMachines = mkOption {
      type = types.attrsOf (types.submodule ({ name, config, ... }: {
        imports = [ instanceOptions ];
        config.imagePackage = lib.mkDefault (
          if config.configurationFile != null
          then mkVMImage name (nixosSystem {
            system = "x86_64-linux";
            modules = [
              config.configurationFile
              "${pkgs.path}/nixos/modules/virtualisation/incus-virtual-machine.nix"
            ];
          })
          else throw "VM ${name}: Either configurationFile or imagePackage must be set"
        );
      }));
      default = {};
      description = ''
        Declarative virtual machine definitions.
        VMs are automatically created, started, and updated.
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
    system.activationScripts.incusEnsureInstances = lib.mkIf hasInstances {
      text = ''
        # Ensure all instances exist and are started
        ${ensureInstancesScript}
      '';
    };

    # Auto-update instances on system activation
    # This runs in the background to avoid blocking activation
    system.activationScripts.updateIncusInstances = lib.mkIf hasInstances {
      text = ''
        # Launch instance updates in background
        (${updateAllScript} &) || true
      '';
      deps = [ "incusEnsureInstances" ];
    };

    # Systemd service for manual instance updates
    systemd.services.incus-instance-updates = {
      description = "Update Incus instances in-place";
      after = [ "incus.service" ];
      requires = [ "incus.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = updateAllScript;
        # Don't fail if some instances can't be updated
        SuccessExitStatus = "0 1";
      };

      # Not wanted by any target (triggered manually or by activation script)
      wantedBy = [];
    };

    # Helper scripts for manual updates
    environment.systemPackages = [
      (pkgs.writeScriptBin "incus-update-instances" ''
        #!${pkgs.bash}/bin/bash
        exec ${pkgs.systemd}/bin/systemctl start incus-instance-updates.service
      '')
      (pkgs.writeScriptBin "incus-update-instance" ''
        #!${pkgs.bash}/bin/bash
        if [ $# -ne 1 ]; then
          echo "Usage: incus-update-instance <instance-name>"
          exit 1
        fi

        INSTANCE="$1"

        # Check if instance is managed
        case "$INSTANCE" in
          ${concatStringsSep "\n          " (mapAttrsToList (name: _: "${name})") allInstances)}
            ${concatStringsSep "\n            " (mapAttrsToList (name: instanceCfg:
              "[ \"$INSTANCE\" = \"${name}\" ] && exec ${mkUpdateScript name instanceCfg}"
            ) allInstances)}
            ;;
          *)
            echo "Error: Instance '$INSTANCE' is not managed by incus-manager"
            echo "Managed instances: ${concatStringsSep ", " (attrNames allInstances)}"
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
