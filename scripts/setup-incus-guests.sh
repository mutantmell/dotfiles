#!/usr/bin/env bash
set -euo pipefail

# Place pre-generated SSH keys into the host-side static directory for Incus guests.
# Keys are bind-mounted into guests at /static, so no incus exec or guest restart needed.
#
# Usage: ./scripts/setup-incus-guests.sh <hostname> <target-host>
# Example: ./scripts/setup-incus-guests.sh calvard root@10.97.20.40

HOSTNAME="${1:-}"
TARGET="${2:-}"

if [[ -z $HOSTNAME || -z $TARGET ]]; then
  echo "Usage: $0 <hostname> <target-host>"
  echo ""
  echo "Places pre-generated SSH host keys from .keys/ into the host's"
  echo "/persist/guests/<name>/static/etc/ssh/ directory. Keys are"
  echo "bind-mounted into guests at /static — no guest restart needed."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="$REPO_ROOT/.keys"
INCUS_GUEST_DIR="$REPO_ROOT/hosts/$HOSTNAME/incus/guests"

if [[ ! -d $INCUS_GUEST_DIR ]]; then
  echo "No Incus guests found for $HOSTNAME"
  exit 0
fi

echo "Placing SSH keys for Incus guests on $HOSTNAME ($TARGET)..."
echo ""

for guest_path in "$INCUS_GUEST_DIR"/*/; do
  [[ -d $guest_path ]] || continue
  guest="$(basename "$guest_path")"

  GUEST_KEY="$KEYS_DIR/${guest}-ssh_host_ed25519_key"
  if [[ ! -f $GUEST_KEY ]]; then
    echo "WARNING: No SSH key found for $guest at $GUEST_KEY — skipping"
    continue
  fi

  STATIC_SSH_DIR="/persist/guests/$guest/static/etc/ssh"

  echo "  $guest: placing SSH host key..."
  # shellcheck disable=SC2029  # $STATIC_SSH_DIR is intentionally expanded client-side
  ssh "$TARGET" "mkdir -p $STATIC_SSH_DIR && chmod 700 $STATIC_SSH_DIR"
  scp "$GUEST_KEY" "$TARGET:$STATIC_SSH_DIR/ssh_host_ed25519_key"
  scp "$GUEST_KEY.pub" "$TARGET:$STATIC_SSH_DIR/ssh_host_ed25519_key.pub"
  # shellcheck disable=SC2029
  ssh "$TARGET" "chmod 600 $STATIC_SSH_DIR/ssh_host_ed25519_key && chmod 644 $STATIC_SSH_DIR/ssh_host_ed25519_key.pub"

  echo "  $guest: done"
done

echo ""
echo "SSH keys placed. Guests will pick them up via /static mount on next boot."
