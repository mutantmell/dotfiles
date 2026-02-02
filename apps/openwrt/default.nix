# OpenWrt management apps
#
# Usage:
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
#   nix run .#openwrt-profiles -- | grep -i <device>
#   nix run .#openwrt-show-config -- <device-name>
{ pkgs }:

{
  # Deploy an OpenWrt image to a device via sysupgrade
  openwrt-deploy = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-deploy" ''
        set -euo pipefail

        if [ $# -lt 2 ]; then
          echo "Usage: nix run .#openwrt-deploy -- <device-name> <device-ip> [--force]"
          echo ""
          echo "Deploys an OpenWrt sysupgrade image to the specified device."
          echo ""
          echo "Arguments:"
          echo "  device-name  Name of the device (as defined in hosts/openwrt/)"
          echo "  device-ip    IP address or hostname of the device"
          echo "  --force      Skip confirmation prompt"
          echo ""
          echo "Example:"
          echo "  nix run .#openwrt-deploy -- fenrir 10.0.10.10"
          exit 1
        fi

        DEVICE="$1"
        TARGET="$2"
        FORCE="''${3:-}"

        # Build the image
        echo "Building image for $DEVICE..."
        IMAGE_PATH=$(nix build --no-link --print-out-paths ".#openwrtImages.$DEVICE" 2>/dev/null)

        if [ -z "$IMAGE_PATH" ]; then
          echo "Error: Failed to build image for $DEVICE"
          echo "Make sure the device is defined in hosts/openwrt/default.nix"
          exit 1
        fi

        # Find the sysupgrade image
        SYSUPGRADE=$(find "$IMAGE_PATH" -name "*-sysupgrade.bin" -o -name "*-sysupgrade.img.gz" | head -1)

        if [ -z "$SYSUPGRADE" ]; then
          echo "Error: No sysupgrade image found in $IMAGE_PATH"
          exit 1
        fi

        echo "Image: $SYSUPGRADE"
        echo "Target: $TARGET"
        echo ""

        if [ "$FORCE" != "--force" ]; then
          read -p "Deploy to $TARGET? This will reboot the device. [y/N] " -n 1 -r
          echo
          if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
          fi
        fi

        echo "Uploading image..."
        ${pkgs.openssh}/bin/scp -O "$SYSUPGRADE" "root@$TARGET:/tmp/sysupgrade.bin"

        echo "Starting sysupgrade (device will reboot)..."
        ${pkgs.openssh}/bin/ssh "root@$TARGET" "sysupgrade -v /tmp/sysupgrade.bin" || true

        echo ""
        echo "Upgrade initiated. Device is rebooting."
        echo "Wait ~2-3 minutes, then verify connectivity."
      '';
    in "${script}";
  };

  # List available OpenWrt device profiles
  openwrt-profiles = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-profiles" ''
        echo "Fetching available OpenWrt profiles..."
        echo "This may take a moment on first run."
        echo ""
        nix run github:astro/nix-openwrt-imagebuilder -- list-profiles "$@"
      '';
    in "${script}";
  };

  # Show UCI configuration that would be applied
  openwrt-show-config = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-show-config" ''
        set -euo pipefail

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-show-config -- <device-name>"
          echo ""
          echo "Shows the UCI configuration that would be applied to the device."
          exit 1
        fi

        DEVICE="$1"

        # Build and extract the uci-defaults script
        IMAGE_PATH=$(nix build --no-link --print-out-paths ".#openwrtImages.$DEVICE" 2>/dev/null)

        if [ -z "$IMAGE_PATH" ]; then
          echo "Error: Failed to build image for $DEVICE"
          exit 1
        fi

        # The config files are in the build output
        if [ -f "$IMAGE_PATH/files/etc/uci-defaults/99-nix-config" ]; then
          cat "$IMAGE_PATH/files/etc/uci-defaults/99-nix-config"
        else
          echo "Searching for config in image..."
          find "$IMAGE_PATH" -name "99-nix-config" -exec cat {} \; 2>/dev/null || \
            echo "Could not find UCI defaults script"
        fi
      '';
    in "${script}";
  };
}
