#!/usr/bin/env bash
set -euo pipefail

# Post-boot Incus guest setup: push pre-generated SSH keys to Incus VMs
# Run this after the host has fully booted and Incus VMs are running.
#
# Usage: ./scripts/setup-incus-guests.sh <hostname> <target-host>
# Example: ./scripts/setup-incus-guests.sh erebonia root@10.97.11.3

HOSTNAME="${1:-}"
TARGET="${2:-}"

if [[ -z $HOSTNAME || -z $TARGET ]]; then
  echo "Usage: $0 <hostname> <target-host>"
  echo ""
  echo "Pushes pre-generated SSH host keys from .keys/ to each Incus guest VM."
  echo "Run after the host has booted and Incus VMs are running."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="$REPO_ROOT/.keys"
INCUS_GUEST_DIR="$REPO_ROOT/hosts/$HOSTNAME/incus/guests"

if [[ ! -d $INCUS_GUEST_DIR ]]; then
  echo "No Incus guests found for $HOSTNAME"
  exit 0
fi

echo "Setting up Incus guests on $HOSTNAME ($TARGET)..."
echo ""

for guest_path in "$INCUS_GUEST_DIR"/*/; do
  [[ -d $guest_path ]] || continue
  guest="$(basename "$guest_path")"

  GUEST_KEY="$KEYS_DIR/${guest}-ssh_host_ed25519_key"
  if [[ ! -f $GUEST_KEY ]]; then
    echo "WARNING: No SSH key found for $guest at $GUEST_KEY — skipping"
    continue
  fi

  echo "  $guest: pushing SSH host key..."
  # shellcheck disable=SC2029  # $guest is intentionally expanded client-side
  ssh "$TARGET" "incus file push - $guest/etc/ssh/ssh_host_ed25519_key --uid=0 --gid=0 --mode=0600" <"$GUEST_KEY"
  # shellcheck disable=SC2029
  ssh "$TARGET" "incus file push - $guest/etc/ssh/ssh_host_ed25519_key.pub --uid=0 --gid=0 --mode=0644" <"$GUEST_KEY.pub"

  echo "  $guest: restarting sshd..."
  # shellcheck disable=SC2029
  ssh "$TARGET" "incus exec $guest -- systemctl restart sshd"

  echo "  $guest: triggering update to activate sops secrets..."
  # shellcheck disable=SC2029
  ssh "$TARGET" "incus-update-instance $guest" || true

  echo "  $guest: done"
done

echo ""
echo "Incus guest setup complete."
