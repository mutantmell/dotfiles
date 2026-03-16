{
  config,
  pkgs,
  lib,
  ...
}:
# Incus Instance Management Module
#
# Manages the lifecycle of Incus containers and virtual machines declaratively.
# Instances are created from pre-built NixOS system closures and updated via
# `nix copy` + `switch-to-configuration` over SSH.
#
# Image safety: mkVMImage and mkContainerImage produce nix store derivations
# containing only the NixOS system closure (binaries, derivations, symlinks).
# No secrets are baked into these images — sops-nix decrypts secrets at
# activation time (runtime), not build time. The encrypted sops files
# referenced in guest configs are not included in the store closure.
#
# This is a generic, extractable module — no project-specific logic.
# Project-specific coordination (auto-discovery, impermanence) lives in
# modules/common/incus.nix.
let
  cfg = config.incus-manager;

  inherit
    (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    mkMerge
    mapAttrsToList
    optionalString
    concatStringsSep
    ;
  inherit (builtins) attrNames;

  hasGuests = cfg.guests != {};

  # Build an image derivation from a NixOS system
  mkVMImage = name: guestCfg:
    pkgs.runCommand "${name}-vm-image" {} ''
      mkdir -p $out
      ln -s ${guestCfg.system.config.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
      ln -s ${guestCfg.system.config.system.build.qemuImage}/*.qcow2 $out/disk.qcow2
    '';

  mkContainerImage = name: guestCfg:
    pkgs.runCommand "${name}-container-image" {} ''
      mkdir -p $out
      ln -s ${guestCfg.system.config.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
      ln -s ${guestCfg.system.config.system.build.tarball}/tarball/*.tar.xz $out/rootfs.tar.xz
    '';

  imageForGuest = name: guestCfg:
    if guestCfg.type == "vm"
    then mkVMImage name guestCfg
    else mkContainerImage name guestCfg;

  # Per-instance ensure script
  mkInstanceEnsureScript = name: guestCfg: let
    image = imageForGuest name guestCfg;
    isVM = guestCfg.type == "vm";
    imageFiles =
      if isVM
      then "${image}/metadata.tar.xz ${image}/disk.qcow2"
      else "${image}/metadata.tar.xz ${image}/rootfs.tar.xz";
    vmFlag = optionalString isVM " --vm";
    profileFlag = optionalString (guestCfg.profile != null) " --profile ${guestCfg.profile}";
  in
    pkgs.writeShellScript "incus-ensure-${name}" ''
      set -e
      INSTANCE="${name}"
      IMAGE_ALIAS="${name}"

      # Import image if alias doesn't exist
      if ! ${pkgs.incus}/bin/incus image list --format=csv -c l | grep -q "^$IMAGE_ALIAS$"; then
        echo "Importing image: $IMAGE_ALIAS"
        ${pkgs.incus}/bin/incus image import ${imageFiles} --alias "$IMAGE_ALIAS"
      fi

      # Create instance if it doesn't exist
      if ! ${pkgs.incus}/bin/incus list --format=csv -c n | grep -q "^$INSTANCE$"; then
        echo "Creating instance: $INSTANCE"
        ${pkgs.incus}/bin/incus init "$IMAGE_ALIAS" "$INSTANCE"${vmFlag}${profileFlag}
        ${optionalString (guestCfg.bridge != null) ''
        ${pkgs.incus}/bin/incus config device add "$INSTANCE" eth0 nic \
          nictype=bridged parent="${guestCfg.bridge}" name=eth0 || true
      ''}
      fi

      # Add static directory mount if configured
      # Containers need shift=true for UID/GID mapping in unprivileged namespaces
      ${optionalString (guestCfg.staticDir != null) ''
        if ! ${pkgs.incus}/bin/incus config device list "$INSTANCE" | grep -q "^static$"; then
          echo "Adding static disk device to $INSTANCE"
          ${pkgs.incus}/bin/incus config device add "$INSTANCE" static disk \
            source="${guestCfg.staticDir}" path=/static${optionalString (!isVM) " shift=true"}
        fi
      ''}

      # Configure auto-start so guest reboots don't leave the instance stopped
      ${optionalString guestCfg.autoStart ''
        ${pkgs.incus}/bin/incus config set "$INSTANCE" boot.autostart=true
      ''}

      # Start if autoStart and not running
      ${optionalString guestCfg.autoStart ''
        if ! ${pkgs.incus}/bin/incus list --format=csv -c ns | grep -q "^$INSTANCE,RUNNING"; then
          echo "Starting instance: $INSTANCE"
          ${pkgs.incus}/bin/incus start "$INSTANCE"
        fi
      ''}
    '';

  # Per-instance update script: push pre-built closure via nix copy + switch-to-configuration
  mkInstanceUpdateScript = name: guestCfg: let
    inherit (guestCfg.system.config.system.build) toplevel;
  in
    pkgs.writeShellScript "incus-update-${name}" ''
      set -e
      INSTANCE="${name}"

      if ! ${pkgs.incus}/bin/incus list --format=csv -c ns | grep -q "^$INSTANCE,RUNNING"; then
        echo "Instance $INSTANCE is not running, skipping update"
        exit 0
      fi

      echo "Updating instance: $INSTANCE"

      # Copy the closure to the instance via SSH
      ${pkgs.nix}/bin/nix copy --to "ssh://root@$INSTANCE" ${toplevel} --no-check-sigs

      # Activate the new configuration
      ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no root@"$INSTANCE" \
        "${toplevel}/bin/switch-to-configuration switch"

      echo "Instance $INSTANCE updated successfully"
    '';

  # Aggregate scripts
  ensureAllScript = pkgs.writeShellScript "incus-ensure-instances" ''
    set -e
    echo "Ensuring Incus instances..."
    ${concatStringsSep "\n" (mapAttrsToList (
        name: guestCfg: "${mkInstanceEnsureScript name guestCfg} || echo 'Warning: Failed to ensure ${name}, continuing...'"
      )
      cfg.guests)}
    echo "Instance check complete."
  '';

  updateAllScript = pkgs.writeShellScript "incus-update-instances" ''
    set -e
    echo "Updating Incus instances..."
    ${concatStringsSep "\n" (mapAttrsToList (
        name: guestCfg: "${mkInstanceUpdateScript name guestCfg} || echo 'Warning: Failed to update ${name}, continuing...'"
      )
      cfg.guests)}
    echo "Instance update complete."
  '';
in {
  options.incus-manager = {
    enable = mkEnableOption "Incus instance management";

    guests = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          type = mkOption {
            type = types.enum ["vm" "container"];
            default = "vm";
            description = "Instance type: vm or container.";
          };

          system = mkOption {
            type = types.unspecified;
            description = "The built NixOS system (result of nixpkgs.lib.nixosSystem or equivalent).";
          };

          profile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Incus profile to apply to this instance.";
          };

          bridge = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Host bridge to attach this instance to via nictype=bridged.";
          };

          autoStart = mkOption {
            type = types.bool;
            default = true;
            description = "Auto-start instance on host boot.";
          };

          staticDir = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Host-side directory to mount at /static in the guest (for SSH keys, etc).";
          };
        };
      });
      default = {};
      description = "Incus guest instances to manage.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      virtualisation.incus.enable = true;
      networking.nftables.enable = true;

      # Incus loads br_netfilter, which forces bridge traffic through nftables.
      # Disable this so bridged VMs/containers can communicate without
      # needing explicit nftables rules for L2 forwarded frames.
      boot.kernel.sysctl = {
        "net.bridge.bridge-nf-call-iptables" = 0;
        "net.bridge.bridge-nf-call-ip6tables" = 0;
      };

      users.groups.incus-admin = {};
    }

    (mkIf hasGuests {
      # Systemd service to ensure instances exist after incus daemon is up
      systemd.services.incus-ensure-instances = {
        description = "Ensure Incus instances exist and are started";
        after = ["incus.service" "incus-preseed.service"];
        wants = ["incus.service"];
        wantedBy = ["multi-user.target"];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = ensureAllScript;
        };
      };

      # Systemd service for updating instances
      # Runs automatically when any guest's NixOS config changes (via restartTriggers),
      # and can also be triggered manually via incus-update-instances helper.
      systemd.services.incus-update-instances = {
        description = "Update Incus instances with pre-built closures";
        after = ["incus-ensure-instances.service"];
        requires = ["incus.service"];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = updateAllScript;
        };

        wantedBy = ["multi-user.target"];
        restartTriggers =
          mapAttrsToList
          (name: guestCfg: guestCfg.system.config.system.build.toplevel)
          cfg.guests;
      };

      # Helper scripts
      environment.systemPackages = [
        (pkgs.writeScriptBin "incus-ensure-instances" ''
          #!${pkgs.bash}/bin/bash
          exec ${pkgs.systemd}/bin/systemctl start incus-ensure-instances.service
        '')
        (pkgs.writeScriptBin "incus-update-instances" ''
          #!${pkgs.bash}/bin/bash
          exec ${pkgs.systemd}/bin/systemctl start incus-update-instances.service
        '')
        (pkgs.writeScriptBin "incus-update-instance" ''
          #!${pkgs.bash}/bin/bash
          if [ $# -ne 1 ]; then
            echo "Usage: incus-update-instance <instance-name>"
            exit 1
          fi
          INSTANCE="$1"
          case "$INSTANCE" in
            ${concatStringsSep "\n            " (mapAttrsToList (
              name: guestCfg: "${name}) exec ${mkInstanceUpdateScript name guestCfg} ;;"
            )
            cfg.guests)}
            *)
              echo "Error: Instance '$INSTANCE' is not managed by incus-manager"
              echo "Managed instances: ${concatStringsSep ", " (attrNames cfg.guests)}"
              exit 1
              ;;
          esac
        '')
      ];
    })
  ]);
}
