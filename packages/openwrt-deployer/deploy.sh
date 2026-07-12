#!/usr/bin/env bash
# openwrt-deploy — deploy an OpenWrt sysupgrade image to a device via SSH
#
# Usage: openwrt-deploy <target-ip> <image-path> [--force] [--ssh-key <path>]
set -euo pipefail

usage() {
  echo "Usage: openwrt-deploy <target-ip> <image-path> [--force] [--ssh-key <path>]"
  echo ""
  echo "Deploys an OpenWrt sysupgrade image to a device via scp + sysupgrade."
  echo ""
  echo "Arguments:"
  echo "  target-ip      IP address or hostname of the device"
  echo "  image-path     Path to the sysupgrade image file"
  echo "  --force        Skip confirmation prompt"
  echo "  --ssh-key PATH Use a specific SSH private key for authentication"
}

if [ $# -lt 2 ]; then
  usage
  exit 1
fi

TARGET="$1"
IMAGE="$2"
shift 2

FORCE=""
SSH_KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
  --force) FORCE="1" ;;
  --ssh-key)
    shift
    SSH_KEY="$1"
    ;;
  *)
    echo "Unknown argument: $1"
    usage
    exit 1
    ;;
  esac
  shift
done

SSH_OPTS=()
if [ -n "$SSH_KEY" ]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

if [ ! -f "$IMAGE" ]; then
  echo "Error: Image file not found: $IMAGE"
  exit 1
fi

IMAGE_SIZE=$(du -h "$IMAGE" | cut -f1)

echo ""
echo "Image:  $IMAGE"
echo "Size:   $IMAGE_SIZE"
echo "Target: $TARGET"
echo ""

if [ -z "$FORCE" ]; then
  read -p "Deploy to $TARGET? This will reboot the device. [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Uploading image..."
scp -O "${SSH_OPTS[@]}" "$IMAGE" "root@$TARGET:/tmp/sysupgrade.bin"

echo "Validating image on target..."
ssh "${SSH_OPTS[@]}" "root@$TARGET" "command -v sysupgrade >/dev/null && sysupgrade -T /tmp/sysupgrade.bin"

echo "Starting sysupgrade (device will reboot)..."
LOG=$(mktemp -t openwrt-sysupgrade-XXXXXX.log)
cleanup() { rm -f "$LOG"; }
trap cleanup EXIT INT TERM HUP
set +e
ssh "${SSH_OPTS[@]}" "root@$TARGET" "echo __OPENWRT_SYSUPGRADE_START__; exec sysupgrade -v /tmp/sysupgrade.bin" >"$LOG" 2>&1
rc=$?
set -e
cat "$LOG"
case "$rc" in
0)
  echo "sysupgrade command completed before disconnect."
  ;;
255)
  if grep -q "__OPENWRT_SYSUPGRADE_START__" "$LOG"; then
    echo "SSH disconnected after sysupgrade started; treating this as expected reboot behavior."
  else
    echo "Error: SSH disconnected before sysupgrade start was confirmed." >&2
    exit 255
  fi
  ;;
*)
  echo "Error: sysupgrade failed before reboot (ssh exit $rc)." >&2
  exit "$rc"
  ;;
esac

echo ""
echo "Upgrade initiated. Device is rebooting."
echo "Wait ~2-3 minutes, then verify connectivity."
echo ""
echo "Deployment complete."
