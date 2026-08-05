# OpenWrt management apps
#
# Build:
#   nix run .#openwrt-build -- <device-name>
#   nix run .#openwrt-build -- <device-name> --no-secrets
#
# Update Image Builder hashes:
#   nix run .#openwrt-update-pins
#
# Deploy:
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
#
# Discovery:
#   nix run .#openwrt-build -- --list-devices
#
# Secrets (hosts/openwrt/secrets/wifi.yaml):
#   Encrypted with sops in binary format. The wrapper calls `sops -d` and pipes
#   the decrypted YAML directly to the builder — secrets never enter the Nix
#   store. Explicit `--secrets-file -` is also read directly from stdin.
#
#   Plain YAML structure (example):
#     wifi:
#       main:
#         ssid: "NetworkName"
#         key: "main-network-password"
#       secondary:
#         ssid: "NetworkName-Alt"
#         key: "alt-network-password"
#       iot:
#         ssid: "NetworkName-IoT"
#         key: "iot-network-password"
#       mesh:
#         id: "your-mesh-id"
#         key: "your-mesh-password"
{
  pkgs,
  openwrtDevices,
  openwrtConfigurations,
  openwrtVmConfigurations,
}: let
  inherit (pkgs) lib;
  owrtData = import ../../lib/common/data/openwrt.nix {inherit lib;};
  builder = pkgs.mmell.openwrt-builder;
  deployer = pkgs.mmell.openwrt-deployer;

  # Device name → config dir lookup (shell case statement)
  # ${drv} interpolation embeds the store path AND adds drv to the closure,
  # so all openwrtConfigurations derivations are built before these scripts run.
  deviceConfigLookup = lib.concatStringsSep "\n" (lib.mapAttrsToList (
      name: drv: "    ${name}) CONFIG_DIR=\"${drv}\" ;;"
    )
    openwrtConfigurations);

  vmConfigLookup = lib.concatStringsSep "\n" (lib.mapAttrsToList (
      name: drv: "    ${name}) VM_CONFIG_DIR=\"${drv}\" ;;"
    )
    openwrtVmConfigurations);

  # Device name → target/subtarget lookup (for update flow)
  deviceTargetLookup = lib.concatStringsSep "\n" (lib.mapAttrsToList (
      name: device: "    ${name}) DEVICE_TARGET=\"${device.target}/${device.subtarget}\" ;;"
    )
    openwrtDevices);

  # All device targets, used by the explicit pin-update tool.
  allTargets = lib.concatStringsSep " " (
    lib.unique (lib.mapAttrsToList (_: device: "${device.target}/${device.subtarget}") openwrtDevices)
  );

  # Device listing info embedded at eval time
  deviceListInfo = lib.concatStringsSep "\n" (lib.mapAttrsToList (
      name: device: "  printf '  %-20s %-10s %s\\n' '${name}' '${device.role}' '${device.profile}'"
    )
    openwrtDevices);

  # Resolve device name to CONFIG_DIR, or error
  resolveDevice = ''
    resolve_device() {
      local DEVICE="$1"
      CONFIG_DIR=""
      case "$DEVICE" in
    ${deviceConfigLookup}
        *)
          echo "Error: Unknown device '$DEVICE'" >&2
          echo "Available devices:" >&2
    ${deviceListInfo}
          exit 1
          ;;
      esac
    }
  '';

  # Resolve device name to DEVICE_TARGET (target/subtarget), or error
  resolveTarget = ''
    resolve_target() {
      local DEVICE="$1"
      DEVICE_TARGET=""
      case "$DEVICE" in
    ${deviceTargetLookup}
        *)
          echo "Error: Unknown device '$DEVICE'" >&2
          exit 1
          ;;
      esac
    }
  '';

  # Find the sops-encrypted secrets file in the repo, if present.
  # Sets SOPS_FILE (empty string if not found).
  discoverSopsFile = ''
    SOPS_FILE=""
    if [ -n "$REPO_ROOT" ]; then
      if [ -f "$REPO_ROOT/hosts/openwrt/secrets/wifi.yaml" ]; then
        SOPS_FILE="$REPO_ROOT/hosts/openwrt/secrets/wifi.yaml"
      fi
    fi
  '';

  # Find a sysupgrade image in a directory, supporting all known image formats.
  # Returns empty string if none found (never errors).
  findSysupgrade = ''
    find_sysupgrade() {
      find "$1" \( -name "*-sysupgrade.bin" -o -name "*-sysupgrade.img.gz" -o -name "*-sysupgrade.itb" \) 2>/dev/null | head -1 || true
    }
  '';

  # Allocate a new private artifact directory for every image assembly. Completed
  # images are deliberately never reused: evaluated configuration, secrets, CLI
  # overrides, and caller SSH keys are all consumed afresh on every invocation.
  createOutputDir = ''
    create_output_dir() {
      local kind="''${1:-build}"
      local base="''${REPO_ROOT:+$REPO_ROOT/openwrt-images}"
      base="''${base:-$(pwd)/openwrt-images}"
      umask 077
      mkdir -p "$base/$DEVICE"
      OUTPUT_DIR=$(${pkgs.coreutils}/bin/mktemp -d "$base/$DEVICE/$kind-$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
    }
  '';

  # Parse the options accepted by the managed build wrapper once. The caller
  # receives normalized builder arguments and an explicit secrets mode instead
  # of passing raw arguments through multiple validation/scanning layers.
  parseManagedBuildArgs = ''
    parse_managed_build_args() {
      BUILDER_ARGS=()
      SECRET_MODE=auto
      SECRET_SOURCE=""
      SHOW_BUILDER_HELP=false
      local arg value
      while [ $# -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
          --config-file|--config-file=*|--output-dir|--output-dir=*|--target|--target=*|--subtarget|--subtarget=*|--profile|--profile=*|--release|--release=*|--package|--package=*|--authorized-key|--authorized-key=*|--image-builder-tarball|--image-builder-tarball=*)
            echo "Error: $arg is fixed by the evaluated device manifest." >&2
            return 1
            ;;
          --no-secrets)
            if [ "$SECRET_MODE" = explicit ]; then
              echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2
              return 1
            fi
            SECRET_MODE=none
            ;;
          --secrets-file)
            [ $# -gt 0 ] || { echo "Error: --secrets-file requires a non-empty value." >&2; return 1; }
            value="$1"
            shift
            [ -n "$value" ] || { echo "Error: --secrets-file requires a non-empty value." >&2; return 1; }
            if [ "$SECRET_MODE" = none ]; then
              echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2
              return 1
            elif [ "$SECRET_MODE" = explicit ]; then
              echo "Error: --secrets-file may only be specified once." >&2
              return 1
            fi
            SECRET_MODE=explicit
            SECRET_SOURCE="$value"
            ;;
          --secrets-file=*)
            value="''${arg#*=}"
            [ -n "$value" ] || { echo "Error: --secrets-file requires a non-empty value." >&2; return 1; }
            if [ "$SECRET_MODE" = none ]; then
              echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2
              return 1
            elif [ "$SECRET_MODE" = explicit ]; then
              echo "Error: --secrets-file may only be specified once." >&2
              return 1
            fi
            SECRET_MODE=explicit
            SECRET_SOURCE="$value"
            ;;
          --cache-dir)
            [ $# -gt 0 ] || { echo "Error: --cache-dir requires a non-empty value." >&2; return 1; }
            value="$1"
            shift
            [ -n "$value" ] || { echo "Error: --cache-dir requires a non-empty value." >&2; return 1; }
            BUILDER_ARGS+=(--cache-dir "$value")
            ;;
          --cache-dir=*)
            value="''${arg#*=}"
            [ -n "$value" ] || { echo "Error: --cache-dir requires a non-empty value." >&2; return 1; }
            BUILDER_ARGS+=(--cache-dir "$value")
            ;;
          --help|-h)
            SHOW_BUILDER_HELP=true
            ;;
          *)
            echo "Error: unknown openwrt-build option: $arg" >&2
            return 1
            ;;
        esac
      done
    }
  '';

  # Run the OpenWrt builder from normalized argument and secret state, piping
  # decrypted secrets via stdin when available.
  # Decrypted bytes exist only in the kernel pipe buffer — never written to disk.
  # Secret-free builds must be requested explicitly with --no-secrets; silently
  # producing an image with disabled radios is too easy to mistake for a
  # deployable image. Explicit --secrets-file values are passed through.
  runBuilder = ''
    run_builder() {
      case "$SECRET_MODE" in
        none)
          ${builder}/bin/openwrt-build "$@" --no-secrets
          ;;
        explicit)
          ${builder}/bin/openwrt-build "$@" --secrets-file "$SECRET_SOURCE"
          ;;
        auto)
          if [ -n "''${OPENWRT_SECRETS_FILE:-}" ]; then
            ${builder}/bin/openwrt-build "$@"
          elif [ -n "''${SOPS_FILE:-}" ]; then
            ${pkgs.sops}/bin/sops -d "$SOPS_FILE" \
              | ${builder}/bin/openwrt-build "$@" --secrets-file -
          else
            echo "Error: no OpenWrt secrets file was found." >&2
            echo "Expected hosts/openwrt/secrets/wifi.yaml in the repository, or pass --secrets-file <file|->." >&2
            echo "For an intentionally credential-free image, pass --no-secrets." >&2
            return 1
          fi
          ;;
        *)
          echo "Error: invalid internal secrets mode: $SECRET_MODE" >&2
          return 1
          ;;
      esac
    }
  '';
in {
  # Build an OpenWrt image using the upstream Image Builder
  openwrt-build = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-build-wrapper" ''
        set -euo pipefail

        ${resolveDevice}

        # Handle --list-devices before anything else
        for arg in "$@"; do
          if [ "$arg" = "--list-devices" ]; then
            echo "Available devices:"
        ${deviceListInfo}
            exit 0
          fi
        done

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-build -- <device-name> [--no-secrets] [--secrets-file <file|->]"
          echo "       nix run .#openwrt-build -- --list-devices"
          exit 1
        fi

        DEVICE="$1"
        shift

        # The managed-device wrapper owns these paths so every invocation uses
        # the evaluated device manifest and a new artifact directory.
        ${parseManagedBuildArgs}
        parse_managed_build_args "$@"

        resolve_device "$DEVICE"

        # Help is purely informational: do not require a repository checkout or
        # secrets, and do not allocate an artifact directory.
        $SHOW_BUILDER_HELP && exec ${builder}/bin/openwrt-build --help

        if [ "$SECRET_MODE" = none ] && [ -n "''${OPENWRT_SECRETS_FILE:-}" ]; then
          echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2
          exit 1
        fi

        # Resolve the repository only to discover its encrypted secrets file.
        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")
        ${discoverSopsFile}
        ${runBuilder}
        ${createOutputDir}
        create_output_dir build
        echo "Artifact directory: $OUTPUT_DIR"
        run_builder --config-file "$CONFIG_DIR/build.json" --output-dir "$OUTPUT_DIR" "''${BUILDER_ARGS[@]}"
      '';
    in "${script}";
  };

  # Updating repository pins is deliberately separate from image assembly.
  openwrt-update-pins = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-update-pins" ''
        set -euo pipefail
        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        exec ${builder}/bin/openwrt-update-pins \
          --hashes-file "$REPO_ROOT/lib/common/data/openwrt-hashes.json" \
          --targets ${allTargets} armsr/armv8 \
          "$@"
      '';
    in "${script}";
  };

  # Deploy an OpenWrt image to a device via sysupgrade
  openwrt-deploy = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-deploy" ''
        set -euo pipefail

        ${resolveDevice}

        if [ $# -lt 2 ]; then
          echo "Usage: nix run .#openwrt-deploy -- <device-name> <device-ip> [--force] [--no-secrets] [--secrets-file <path|->] [--ssh-key <path>]"
          echo ""
          echo "Builds and deploys an OpenWrt sysupgrade image to the specified device."
          echo "Secrets are baked into the image — no post-deploy SSH step needed."
          echo "Always assembles a fresh image from the current config and secrets."
          echo ""
          echo "Arguments:"
          echo "  device-name      Name of the device (as defined in hosts/openwrt/)"
          echo "  device-ip        IP address or hostname of the device"
          echo "  --force          Skip confirmation prompt"
          echo "  --no-secrets     Build without WiFi secrets (radios will be disabled)"
          echo "  --secrets-file   Use explicit plain secrets YAML for image build"
          echo "  --ssh-key PATH   Use a specific SSH private key for authentication"
          echo ""
          echo "Example:"
          echo "  nix run .#openwrt-deploy -- bt8bridge 10.91.10.4"
          echo "  nix run .#openwrt-deploy -- bt8bridge 10.91.10.4 --ssh-key ~/.ssh/id_ed25519"
          exit 1
        fi

        DEVICE="$1"
        TARGET="$2"
        shift 2
        resolve_device "$DEVICE"

        SECRET_MODE=auto
        SECRET_SOURCE=""
        DEPLOY_ARGS=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --force)
              DEPLOY_ARGS+=(--force)
              ;;
            --no-secrets)
              [ "$SECRET_MODE" != explicit ] || { echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2; exit 1; }
              SECRET_MODE=none
              ;;
            --secrets-file)
              shift
              [ $# -gt 0 ] && [ -n "$1" ] || { echo "Error: --secrets-file requires a non-empty path or -" >&2; exit 1; }
              [ "$SECRET_MODE" != none ] || { echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2; exit 1; }
              [ "$SECRET_MODE" != explicit ] || { echo "Error: --secrets-file may only be specified once." >&2; exit 1; }
              SECRET_MODE=explicit
              SECRET_SOURCE="$1"
              ;;
            --secrets-file=*)
              value="''${1#*=}"
              [ -n "$value" ] || { echo "Error: --secrets-file requires a non-empty path or -" >&2; exit 1; }
              [ "$SECRET_MODE" != none ] || { echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2; exit 1; }
              [ "$SECRET_MODE" != explicit ] || { echo "Error: --secrets-file may only be specified once." >&2; exit 1; }
              SECRET_MODE=explicit
              SECRET_SOURCE="$value"
              ;;
            --ssh-key)
              shift
              [ $# -gt 0 ] || { echo "Error: --ssh-key requires a path" >&2; exit 1; }
              DEPLOY_ARGS+=(--ssh-key "$1")
              ;;
            *)
              echo "Unknown argument: $1" >&2
              exit 1
              ;;
          esac
          shift
        done

        if [ "$SECRET_MODE" = none ] && [ -n "''${OPENWRT_SECRETS_FILE:-}" ]; then
          echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2
          exit 1
        fi

        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")
        ${discoverSopsFile}
        ${runBuilder}
        ${findSysupgrade}
        ${createOutputDir}
        create_output_dir deploy
        echo "Artifact directory: $OUTPUT_DIR"
        run_builder \
          --config-file "$CONFIG_DIR/build.json" \
          --output-dir "$OUTPUT_DIR"

        SYSUPGRADE=$(find_sysupgrade "$OUTPUT_DIR")
        if [ -z "$SYSUPGRADE" ]; then
          echo "Error: No sysupgrade image found in $OUTPUT_DIR"
          exit 1
        fi

        # Prove that the returned device is running this evaluated configuration.
        # The image digest separately covers injected secret material.
        DEPLOY_ARGS+=(
          --expected-hostname "$DEVICE"
          --expected-build-id "$(${pkgs.jq}/bin/jq -r .buildId "$CONFIG_DIR/build.json")"
          --verify-command "ubus call system board >/dev/null"
        )
        ${deployer}/bin/openwrt-deploy "$TARGET" "$SYSUPGRADE" "''${DEPLOY_ARGS[@]}"
      '';
    in "${script}";
  };

  # Build and run an OpenWrt aarch64 VM for testing a device's UCI configuration.
  #
  # Uses the armsr/armv8 OpenWrt target (same aarch64 architecture as most devices)
  # and boots the initramfs kernel image in qemu-system-aarch64. The UCI config is
  # baked into the initramfs, so the system starts up fully configured in memory —
  # no disk image, no UEFI firmware needed. Clean state on every boot.
  #
  # For MIPS devices (ramips/mt7621, realtek/rtl838x), armsr/armv8 is a different
  # architecture, but UCI config, firewall rules, and DHCP are all architecture-
  # independent — the VM still provides a useful config correctness test.
  #
  # Runs as TCG emulation (no KVM on x86_64 hosts) — OpenWrt is small enough that
  # this is fast enough for configuration verification.
  openwrt-run = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-run" ''
        set -euo pipefail

        ${resolveDevice}
        ${resolveTarget}

        ROOTFS_IMG=""
        cleanup() { [ -n "$ROOTFS_IMG" ] && rm -f "$ROOTFS_IMG" || true; }
        trap cleanup EXIT INT TERM HUP

        usage() {
          echo "Usage: nix run .#openwrt-run -- <device-name> [options]"
          echo ""
          echo "Builds and runs the device's UCI configuration in a QEMU aarch64 VM."
          echo "Uses armsr/armv8 (same architecture as most devices) with the UCI config"
          echo "baked into the rootfs. The serial console is connected to your terminal"
          echo "directly — no SSH required. Use Ctrl-A X to quit QEMU."
          echo ""
          echo "SSH is also available on localhost:<ssh-port> from another terminal."
          echo "SSH uses the authorized keys from the evaluated device manifest."
          echo ""
          echo "Arguments:"
          echo "  device-name           Name of the device (as defined in hosts/openwrt/)"
          echo ""
          echo "Options:"
          echo "  --no-secrets          Build without WiFi/network secrets"
          echo "  --secrets-file PATH   Use explicit plain secrets YAML for image build"
          echo "  --ssh-port PORT       Host port for SSH (default: 2222)"
          echo "  --web-port PORT       Host port for LuCI web UI (default: 8080)"
          echo "  --memory MB           VM memory in MB (default: 256)"
          echo "  --kernel-file PATH    Use a pre-built kernel (skip build step)"
          echo "  --rootfs-gz PATH      Use a pre-built ext4 rootfs .img.gz (skip build step;"
          echo "                        auto-detected from kernel directory if omitted)"
          echo "  --init-shell          Boot directly to /bin/sh (for automated image tests)"
          exit 1
        }

        if [ $# -lt 1 ]; then
          usage
        fi

        DEVICE="$1"
        shift

        SECRET_MODE=auto
        SECRET_SOURCE=""
        SSH_PORT=2222
        WEB_PORT=8080
        MEMORY=256
        KERNEL_FILE=""
        ROOTFS_GZ=""
        INIT_SHELL_ARG=""

        while [ $# -gt 0 ]; do
          case "$1" in
            --no-secrets)
              [ "$SECRET_MODE" != explicit ] || { echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2; exit 1; }
              SECRET_MODE=none
              ;;
            --secrets-file)
              shift
              [ $# -gt 0 ] && [ -n "$1" ] || { echo "Error: --secrets-file requires a non-empty path or -" >&2; exit 1; }
              [ "$SECRET_MODE" != none ] || { echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2; exit 1; }
              [ "$SECRET_MODE" != explicit ] || { echo "Error: --secrets-file may only be specified once." >&2; exit 1; }
              SECRET_MODE=explicit
              SECRET_SOURCE="$1"
              ;;
            --secrets-file=*)
              value="''${1#*=}"
              [ -n "$value" ] || { echo "Error: --secrets-file requires a non-empty path or -" >&2; exit 1; }
              [ "$SECRET_MODE" != none ] || { echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2; exit 1; }
              [ "$SECRET_MODE" != explicit ] || { echo "Error: --secrets-file may only be specified once." >&2; exit 1; }
              SECRET_MODE=explicit
              SECRET_SOURCE="$value"
              ;;
            --ssh-port)     shift; SSH_PORT="$1" ;;
            --web-port)     shift; WEB_PORT="$1" ;;
            --memory)       shift; MEMORY="$1" ;;
            --kernel-file)  shift; KERNEL_FILE="$1" ;;
            --rootfs-gz)    shift; ROOTFS_GZ="$1" ;;
            --init-shell)   INIT_SHELL_ARG="init=/bin/sh" ;;
            --help|-h)      usage ;;
            *)              echo "Unknown option: $1" >&2; usage ;;
          esac
          shift
        done

        if [ "$SECRET_MODE" = none ] && [ -n "''${OPENWRT_SECRETS_FILE:-}" ]; then
          echo "Error: --no-secrets cannot be combined with an explicit secrets source." >&2
          exit 1
        fi

        if [ -z "$KERNEL_FILE" ]; then
          resolve_device "$DEVICE"
          resolve_target "$DEVICE"
          VM_CONFIG_DIR=""
          case "$DEVICE" in
        ${vmConfigLookup}
          esac
          [ -n "$VM_CONFIG_DIR" ] || { echo "Error: no VM manifest for $DEVICE" >&2; exit 1; }
          REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")
          ${discoverSopsFile}
          ${createOutputDir}

          create_output_dir vm-armsr-armv8

          # Warn when the device's native architecture differs from the armsr/armv8 VM.
          case "$DEVICE_TARGET" in
            mediatek/mt7622) ;;
            *)
              echo "Note: $DEVICE uses target $DEVICE_TARGET (MIPS architecture)."
              echo "      Testing on armsr/armv8 (aarch64) — UCI config and firewall rules"
              echo "      are architecture-independent, so this is still a valid config test."
              echo ""
              ;;
          esac

          ${runBuilder}

          echo "Building aarch64 VM image for $DEVICE..."
          echo "Artifact directory: $OUTPUT_DIR"
          run_builder \
            --config-file "$VM_CONFIG_DIR/build.json" \
            --output-dir "$OUTPUT_DIR"

          # armsr/armv8 generic profile produces a separate kernel and ext4 rootfs:
          #   *-kernel.bin              — plain kernel binary
          #   *-ext4-rootfs.img.gz      — ext4 rootfs image (contains our UCI config)
          # QEMU boots with -kernel + a virtio disk drive (no UEFI needed).
          KERNEL_FILE=$(find "$OUTPUT_DIR" -name "*-kernel.bin" 2>/dev/null | head -1 || true)
          ROOTFS_GZ=$(find "$OUTPUT_DIR" -name "*-ext4-rootfs.img.gz" 2>/dev/null | head -1 || true)
          if [ -z "$KERNEL_FILE" ] || [ -z "$ROOTFS_GZ" ]; then
            echo "Error: Could not find kernel or ext4 rootfs image in $OUTPUT_DIR" >&2
            ls "$OUTPUT_DIR" >&2 || true
            exit 1
          fi
        fi

        # When --kernel-file is given without --rootfs-gz, auto-detect from the
        # same directory (the two files are always built together).
        if [ -z "$ROOTFS_GZ" ]; then
          ROOTFS_GZ=$(find "$(dirname "$KERNEL_FILE")" -name "*-ext4-rootfs.img.gz" 2>/dev/null | head -1 || true)
          if [ -z "$ROOTFS_GZ" ]; then
            echo "Error: No ext4 rootfs image found alongside $KERNEL_FILE" >&2
            echo "       Use --rootfs-gz to specify it explicitly." >&2
            exit 1
          fi
        fi

        # Decompress the freshly assembled rootfs, then copy it to a temp file for
        # this QEMU run. UCI defaults (/etc/uci-defaults/) run on first boot and
        # delete themselves, and VM writes must not alter the retained artifact.
        ROOTFS_GOLDEN="''${ROOTFS_GZ%.gz}"
        echo "Decompressing rootfs image..."
        ${pkgs.gzip}/bin/zcat "$ROOTFS_GZ" > "''${ROOTFS_GOLDEN}.tmp"
        mv "''${ROOTFS_GOLDEN}.tmp" "$ROOTFS_GOLDEN"
        ROOTFS_IMG=$(mktemp -t openwrt-rootfs-XXXXXX.img)
        ${pkgs.coreutils}/bin/cp "$ROOTFS_GOLDEN" "$ROOTFS_IMG"

        echo "Kernel: $KERNEL_FILE"
        echo "SSH:    localhost:$SSH_PORT (from another terminal)"
        echo "Web:    http://localhost:$WEB_PORT"
        echo ""
        echo "Starting VM... (Ctrl-A X to quit, Ctrl-A C for QEMU monitor)"
        echo ""

        # -nographic: serial console on stdin/stdout (no separate window needed).
        # The ext4 rootfs is attached as a virtio-blk disk; root=/dev/vda tells
        # the kernel where to find it. Port forwarding allows SSH/web from another
        # terminal while this one shows the serial console.
        ${pkgs.qemu}/bin/qemu-system-aarch64 \
          -M virt \
          -cpu cortex-a53 \
          -m "$MEMORY" \
          -nographic \
          -kernel "$KERNEL_FILE" \
          -drive "file=$ROOTFS_IMG,format=raw,if=virtio" \
          -append "root=/dev/vda rootwait rw console=ttyAMA0 $INIT_SHELL_ARG" \
          -device virtio-rng-pci \
          -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22,hostfwd=tcp::$WEB_PORT-:80" \
          -device virtio-net-pci,netdev=net0
      '';
    in "${script}";
  };

  # Networked end-to-end smoke test. Image Builder downloads package feeds, so
  # this intentionally runs outside the network-isolated Nix build sandbox.
  openwrt-vm-smoke = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-vm-smoke" ''
        set -euo pipefail

        cd "$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
        OPENWRT_RUN_PROGRAM="$(${pkgs.nix}/bin/nix build \
          .#apps.x86_64-linux.openwrt-run.program \
          --no-link --print-out-paths)"
        export OPENWRT_RUN_PROGRAM
        export OPENWRT_SMOKE_SSH_PORT=$((20000 + $$ % 10000))
        export OPENWRT_SMOKE_WEB_PORT=$((30000 + $$ % 10000))
        OPENWRT_SMOKE_SECRETS_FILE=$(${pkgs.coreutils}/bin/mktemp -t openwrt-smoke-secrets-XXXXXX.yaml)
        export OPENWRT_SMOKE_SECRETS_FILE
        cleanup() { rm -f "$OPENWRT_SMOKE_SECRETS_FILE"; }
        trap cleanup EXIT INT TERM HUP
        chmod 0600 "$OPENWRT_SMOKE_SECRETS_FILE"
        # This is intentionally plain, fake test data created only at runtime;
        # no real sops-encrypted secrets are read by the smoke test.
        ${pkgs.coreutils}/bin/printf '%s\n' \
          'bt8bridge:' \
          '  mesh:' \
          '    id: fake-mesh-id' \
          '    key: fake-mesh-key' \
          '  aps:' \
          '    guest-main:' \
          '      id: fake-main-ssid' \
          '      key: fake-main'"'"'key' \
          '    guest-secondary:' \
          '      id: fake-secondary-ssid' \
          '      key: fake-secondary-key' \
          '    game:' \
          '      id: fake-game-ssid' \
          '      key: fake-game-key' \
          > "$OPENWRT_SMOKE_SECRETS_FILE"

        ${pkgs.expect}/bin/expect <<'EXPECT_EOF'
          set timeout 300
          log_user 1
          spawn $env(OPENWRT_RUN_PROGRAM) bt8bridge \
            --secrets-file $env(OPENWRT_SMOKE_SECRETS_FILE) --init-shell \
            --ssh-port $env(OPENWRT_SMOKE_SSH_PORT) \
            --web-port $env(OPENWRT_SMOKE_WEB_PORT)

          expect {
            -re {[/~] # $} {}
            timeout {
              puts stderr "Timed out waiting for the OpenWrt init shell"
              exit 1
            }
            eof {
              puts stderr "QEMU exited before the OpenWrt console became ready"
              exit 1
            }
          }
          # init=/bin/sh deliberately avoids starting hardware-specific services,
          # but it also bypasses OpenWrt's base UCI package creation. Create the
          # empty packages that firstboot would provide before applying the
          # generated defaults script.
          send "touch /etc/config/dhcp /etc/config/firewall /etc/config/network\r"
          expect -re {[/~] # $}
          send "touch /etc/config/system /etc/config/wireless; mkdir -p /var/lock\r"
          expect -re {[/~] # $}
          send "/etc/uci-defaults/99-nix-config\r"
          expect -re {[/~] # $}

          foreach {command expected description} {
            {uci -q get system.system.hostname} bt8bridge hostname
            {uci -q get network.bat0.proto} batadv batman-interface
            {uci -q get wireless.guest_main.ssid} fake-main-ssid main-ssid
            {uci -q get wireless.guest_main.key} {fake-main'key} main-key
            {uci -q get wireless.guest_secondary.ssid} fake-secondary-ssid secondary-ssid
            {uci -q get wireless.guest_secondary.key} fake-secondary-key secondary-key
            {uci -q get wireless.game.ssid} fake-game-ssid game-ssid
            {uci -q get wireless.game.key} fake-game-key game-key
            {uci -q get wireless.game.network} guest_l2 game-vlan-30-bridge
            {uci -q get wireless.batmesh.mesh_id} fake-mesh-id mesh-id
            {uci -q get wireless.batmesh.key} fake-mesh-key mesh-key
            {uci -q get wireless.radio0.disabled} 0 radio0-state
            {uci -q get wireless.radio1.disabled} 0 radio1-state
            {uci -q get wireless.radio2.disabled} 0 radio2-state
          } {
            send "$command\r"
            expect {
              -re "\\r+\\n$expected\\r+\\n" {}
              timeout {
                puts stderr "OpenWrt $description configuration did not match $expected"
                exit 1
              }
              eof {
                puts stderr "QEMU exited during $description verification"
                exit 1
              }
            }
            expect -re {[/~] # $}
          }
          send "\001x"
          expect eof
        EXPECT_EOF
      '';
    in "${script}";
  };

  # Networked destructive-upgrade test against a disposable x86 OpenWrt VM.
  openwrt-deployer-vm = {
    type = "app";
    program = let
      imageBuilder = pkgs.fetchurl {
        url = "https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64.tar.zst";
        hash = owrtData.imageBuilderHashes."25.12.5"."x86/64";
      };
      script = pkgs.writeShellScript "openwrt-deployer-vm" ''
        export OPENWRT_BUILDER=${builder}/bin/openwrt-build
        export OPENWRT_DEPLOYER=${deployer}/bin/openwrt-deploy
        export OPENWRT_IMAGEBUILDER=${imageBuilder}
        export OPENWRT_VM_FIXTURES=${../../tests/openwrt/fixtures}
        export PATH=${lib.makeBinPath [pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gzip pkgs.jq pkgs.openssh pkgs.qemu]}:$PATH
        exec ${../../tests/openwrt/deployer-vm.sh}
      '';
    in "${script}";
  };
}
