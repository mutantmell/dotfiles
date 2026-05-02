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
# `incus exec` with differential `nix-store --export/--import` + `switch-to-configuration`.
# This avoids SSH key management and works even when guest networking is broken.
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
      ln -s ${guestCfg.system.config.system.build.diskoImages}/*.qcow2 $out/disk.qcow2
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

      # Import or update image
      # Track the nix store path of the image derivation in a marker file.
      # When the NixOS config changes, the derivation path changes, triggering
      # a reimport so that any newly created instances use the latest image.
      IMAGE_MARKER="/var/lib/incus/.image-source-$IMAGE_ALIAS"
      EXPECTED_SOURCE="${image}"

      if [ -f "$IMAGE_MARKER" ] && [ "$(cat "$IMAGE_MARKER")" = "$EXPECTED_SOURCE" ]; then
        echo "Image $IMAGE_ALIAS is up to date"
      else
        if ${pkgs.incus}/bin/incus image list --format=csv -c l | grep -q "^$IMAGE_ALIAS$"; then
          echo "Image $IMAGE_ALIAS has changed, replacing..."
          ${pkgs.incus}/bin/incus image delete "$IMAGE_ALIAS"
        fi
        echo "Importing image: $IMAGE_ALIAS"
        ${pkgs.incus}/bin/incus image import ${imageFiles} --alias "$IMAGE_ALIAS"
        echo "$EXPECTED_SOURCE" > "$IMAGE_MARKER"
      fi

      # Create instance if it doesn't exist
      if ! ${pkgs.incus}/bin/incus list --format=csv -c n | grep -q "^$INSTANCE$"; then
        echo "Creating instance: $INSTANCE"
        ${pkgs.incus}/bin/incus init "$IMAGE_ALIAS" "$INSTANCE"${vmFlag}${profileFlag}
        ${optionalString (guestCfg.parent != null) ''
        ${pkgs.incus}/bin/incus config device add "$INSTANCE" eth0 nic \
          nictype=${guestCfg.nictype} parent="${guestCfg.parent}" name=eth0 || true
      ''}
      fi

      # Reconcile NIC parent if it has drifted (e.g. VLAN or nictype migration)
      ${optionalString (guestCfg.parent != null) ''
        CURRENT_PARENT=$(${pkgs.incus}/bin/incus config device get "$INSTANCE" eth0 parent 2>/dev/null || true)
        CURRENT_NICTYPE=$(${pkgs.incus}/bin/incus config device get "$INSTANCE" eth0 nictype 2>/dev/null || true)
        if [ "$CURRENT_PARENT" != "${guestCfg.parent}" ] || [ "$CURRENT_NICTYPE" != "${guestCfg.nictype}" ]; then
          echo "Updating $INSTANCE eth0: $CURRENT_NICTYPE:$CURRENT_PARENT -> ${guestCfg.nictype}:${guestCfg.parent}"
          ${pkgs.incus}/bin/incus config device set "$INSTANCE" eth0 nictype=${guestCfg.nictype}
          ${pkgs.incus}/bin/incus config device set "$INSTANCE" eth0 parent "${guestCfg.parent}"
        fi
      ''}

      # Override root disk size if configured
      ${optionalString (guestCfg.limits.disk != null) ''
        echo "Setting root disk size for $INSTANCE to ${guestCfg.limits.disk}"
        ${pkgs.incus}/bin/incus config device override "$INSTANCE" root size=${guestCfg.limits.disk} 2>/dev/null || \
          ${pkgs.incus}/bin/incus config device set "$INSTANCE" root size=${guestCfg.limits.disk}
      ''}

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

      # Wait for the instance agent to be ready so downstream services
      # (e.g. incus-update-instances) can use incus exec immediately
      ${optionalString guestCfg.autoStart ''
        echo "Waiting for agent in $INSTANCE..."
        ${pkgs.incus}/bin/incus wait "$INSTANCE" agent
      ''}
    '';

  # Per-instance update script: push pre-built closure via incus exec + switch-to-configuration
  # Uses incus exec instead of SSH to avoid key management issues and work even
  # when guest networking is broken. Differential transfer: only missing store
  # paths are exported.
  #
  # Activation mode is passed as the first argument:
  #   auto   — (default) try switch, fall back to boot if inhibited
  #   switch — only switch (fails on inhibited transitions)
  #   boot   — stage as the boot default; reboot the guest to apply
  mkInstanceUpdateScript = name: guestCfg: let
    inherit (guestCfg.system.config.system.build) toplevel;
    incus = "${pkgs.incus}/bin/incus";
    nix-store = "${pkgs.nix}/bin/nix-store";
    # Guest-side paths — NixOS puts binaries in /run/current-system/sw/bin/,
    # not in /usr/bin or /bin, so incus exec's default PATH won't find them.
    guest-nix-env = "/run/current-system/sw/bin/nix-env";
    guest-nix-store = "/run/current-system/sw/bin/nix-store";
    guest-readlink = "/run/current-system/sw/bin/readlink";
    guest-xargs = "/run/current-system/sw/bin/xargs";
  in
    pkgs.writeShellScript "incus-update-${name}" ''
      set -e
      INSTANCE="${name}"

      MODE="''${1:-auto}"
      case "$MODE" in
        auto|switch|boot) ;;
        *) echo "Error: invalid mode '$MODE' (expected: auto, switch, boot)" >&2; exit 1 ;;
      esac

      if ! ${incus} list --format=csv -c ns | grep -q "^$INSTANCE,RUNNING"; then
        echo "Instance $INSTANCE is not running, skipping update"
        exit 0
      fi

      # Skip if the system profile already points at the target generation.
      # We update the profile ourselves below, so this is idempotent across
      # a previous run that staged a generation but hasn't been rebooted yet.
      # `readlink -f` resolves all the way to the toplevel store path; plain
      # readlink would only return the relative `system-N-link`.
      CURRENT=$(${incus} exec "$INSTANCE" -- ${guest-readlink} -f /nix/var/nix/profiles/system 2>/dev/null) || true
      if [ "$CURRENT" = "${toplevel}" ]; then
        echo "Instance $INSTANCE already at target generation, skipping"
        exit 0
      fi

      echo "Updating instance: $INSTANCE (mode=$MODE)"

      # Apply resource limits (non-fatal — live resizing can fail under memory
      # pressure or other transient conditions; the config switch should still proceed
      # and limits will apply on next reboot)
      ${optionalString (guestCfg.limits.cpu != null) ''
        CURRENT_CPU=$(${incus} config get "$INSTANCE" limits.cpu 2>/dev/null || true)
        if [ "$CURRENT_CPU" != "${guestCfg.limits.cpu}" ]; then
          ${incus} config set "$INSTANCE" limits.cpu=${guestCfg.limits.cpu} || \
            echo "Warning: failed to set CPU limit for $INSTANCE, continuing..."
        fi
      ''}
      ${optionalString (guestCfg.limits.memory != null) ''
        CURRENT_MEM=$(${incus} config get "$INSTANCE" limits.memory 2>/dev/null || true)
        if [ "$CURRENT_MEM" != "${guestCfg.limits.memory}" ]; then
          ${incus} config set "$INSTANCE" limits.memory=${guestCfg.limits.memory} || \
            echo "Warning: failed to set memory limit for $INSTANCE, continuing..."
        fi
      ''}
      ${optionalString (guestCfg.limits.disk != null) ''
        CURRENT_DISK=$(${incus} config device get "$INSTANCE" root size 2>/dev/null || true)
        if [ "$CURRENT_DISK" != "${guestCfg.limits.disk}" ]; then
          echo "Updating root disk size for $INSTANCE to ${guestCfg.limits.disk}"
          ${incus} config device set "$INSTANCE" root size=${guestCfg.limits.disk} 2>/dev/null || \
            ${incus} config device override "$INSTANCE" root size=${guestCfg.limits.disk} || \
            echo "Warning: failed to set disk limit for $INSTANCE, continuing..."
        fi
      ''}

      # Find store paths missing from the guest (differential transfer)
      ALL_PATHS=$(${nix-store} -qR ${toplevel})
      MISSING=$(echo "$ALL_PATHS" | ${incus} exec "$INSTANCE" -- \
        ${guest-xargs} ${guest-nix-store} --check-validity --print-invalid 2>/dev/null) || true

      if [ -n "$MISSING" ]; then
        echo "Copying $(echo "$MISSING" | wc -w) store paths to $INSTANCE..."
        ${nix-store} --export $MISSING | ${incus} exec "$INSTANCE" -- ${guest-nix-store} --import
      else
        echo "All store paths already present in $INSTANCE"
      fi

      # Update the system profile so a new `/nix/var/nix/profiles/system-N-link`
      # is created for the target generation. The bootloader installer enumerates
      # generations from these symlinks — without this step, calling
      # `switch-to-configuration` directly (rather than via nixos-rebuild) leaves
      # the profile stale, no new BLS entry is written to /boot, and the guest
      # reverts to the previous generation on reboot. nixos-rebuild does this
      # same step before invoking switch-to-configuration.
      ${incus} exec "$INSTANCE" -- ${guest-nix-env} \
        -p /nix/var/nix/profiles/system --set ${toplevel}

      # Activate the new configuration.
      # In `auto` mode, attempt switch first; if NixOS' pre-switch checks
      # (e.g. switchInhibitors triggered by dbus/systemd transitions that
      # cannot be applied live) reject it, fall back to `boot` so the new
      # generation is installed as the systemd-boot default. The user must
      # reboot the guest to actually apply.
      case "$MODE" in
        switch)
          ${incus} exec "$INSTANCE" -- ${toplevel}/bin/switch-to-configuration switch
          echo "Instance $INSTANCE updated successfully"
          ;;
        boot)
          ${incus} exec "$INSTANCE" -- ${toplevel}/bin/switch-to-configuration boot
          echo ""
          echo "*** $INSTANCE: new generation staged for next boot. Reboot to apply: incus restart $INSTANCE ***"
          ;;
        auto)
          SWITCH_LOG=$(mktemp)
          trap 'rm -f "$SWITCH_LOG"' EXIT
          set +e
          ${incus} exec "$INSTANCE" -- ${toplevel}/bin/switch-to-configuration switch 2>&1 | tee "$SWITCH_LOG"
          SWITCH_RC=''${PIPESTATUS[0]}
          set -e
          if [ "$SWITCH_RC" -eq 0 ]; then
            echo "Instance $INSTANCE updated successfully"
          elif grep -qE 'Pre-switch check|switchInhibitors' "$SWITCH_LOG"; then
            echo ""
            echo "Switch inhibited for $INSTANCE — staging for next boot..."
            ${incus} exec "$INSTANCE" -- ${toplevel}/bin/switch-to-configuration boot
            echo ""
            echo "*** $INSTANCE: switch was inhibited; new generation staged for next boot. Reboot to apply: incus restart $INSTANCE ***"
          else
            echo "Error: switch-to-configuration failed for $INSTANCE (rc=$SWITCH_RC)" >&2
            exit "$SWITCH_RC"
          fi
          ;;
      esac
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

          parent = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Host interface to attach this instance to (bridge for nictype=bridged, parent interface for nictype=macvlan).";
          };

          nictype = mkOption {
            type = types.enum ["bridged" "macvlan"];
            default = "bridged";
            description = "NIC type for the instance's primary network interface.";
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

          limits = {
            cpu = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "CPU limit for this instance (e.g. \"4\"). Applied via incus config set.";
              example = "4";
            };

            memory = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Memory limit for this instance (e.g. \"8GB\"). Applied via incus config set.";
              example = "8GB";
            };

            disk = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Root disk size for this instance (e.g. \"100GB\"). Overrides the profile's root disk size.";
              example = "100GB";
            };
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
      # Workaround for upstream nixpkgs bug: virtualisation.incus.bucketSupport
      # has option type `bool` but the module's own default is null, causing an
      # eval error. Set explicitly to false (we don't use S3 buckets / minio).
      # Remove once nixpkgs ships a fix.
      virtualisation.incus.bucketSupport = false;
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
        requires = ["incus.service"];
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
        after = ["incus.service" "incus-ensure-instances.service"];
        requires = ["incus.service" "incus-ensure-instances.service"];

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
          set -e
          MODE="auto"
          while [ $# -gt 0 ]; do
            case "$1" in
              --boot) MODE="boot"; shift ;;
              --switch) MODE="switch"; shift ;;
              --auto) MODE="auto"; shift ;;
              --) shift; break ;;
              -*) echo "Unknown flag: $1" >&2; exit 1 ;;
              *) break ;;
            esac
          done
          if [ $# -ne 1 ]; then
            echo "Usage: incus-update-instance [--boot|--switch|--auto] <instance-name>"
            exit 1
          fi
          INSTANCE="$1"
          case "$INSTANCE" in
            ${concatStringsSep "\n            " (mapAttrsToList (
              name: guestCfg: "${name}) exec ${mkInstanceUpdateScript name guestCfg} \"$MODE\" ;;"
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
