#!/usr/bin/env bash
set -euo pipefail

# nixos-anywhere deployment wrapper with LUKS encryption support
# Usage: ./scripts/deploy-nixos-anywhere.sh <hostname> <target-ip> [extra-args]

HOSTNAME="${1:-}"
TARGET="${2:-}"

if [[ -z "$HOSTNAME" || -z "$TARGET" ]]; then
    echo "Usage: $0 <hostname> <target-ip> [extra-args]"
    echo ""
    echo "Examples:"
    echo "  $0 thebeyond root@192.168.1.100"
    echo "  $0 calvard user@example.com --build-on-remote"
    echo ""
    echo "Available hosts:"
    nix flake show 2>/dev/null | grep "nixosConfigurations" -A 10 | grep "├" | sed 's/.*├─ /  - /'
    exit 1
fi

shift 2
EXTRA_ARGS="$@"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Generate encryption keyfile
KEYFILE_DIR=$(mktemp -d)
KEYFILE="$KEYFILE_DIR/disk.key"
trap "rm -rf $KEYFILE_DIR" EXIT

echo "Generating LUKS encryption keyfile..."
# Generate a text-safe key (base64) so it survives bash command substitution
# in disko's passwordFile handling and can be stored in a password manager.
head -c 64 /dev/urandom | base64 -w0 > "$KEYFILE"
chmod 600 "$KEYFILE"

echo ""
echo "======================================"
echo "nixos-anywhere Deployment (Encrypted)"
echo "======================================"
echo "Host:       $HOSTNAME"
echo "Target:     $TARGET"
echo "Flake:      $REPO_ROOT#$HOSTNAME"
echo "Encryption: LUKS with keyfile"
echo "Extra args: ${EXTRA_ARGS:-none}"
echo "======================================"
echo ""

# Confirm deployment
read -p "Deploy $HOSTNAME to $TARGET? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    rm -rf "$KEYFILE_DIR"
    exit 1
fi

# Clear any stale SSH host keys for the target (reinstalls generate new keys)
TARGET_HOST="${TARGET#*@}" # strip user@ prefix: "root@1.2.3.4" -> "1.2.3.4"
ssh-keygen -R "$TARGET_HOST" 2>/dev/null || true

# Save keyfile to repo for later use (gitignored)
mkdir -p "$REPO_ROOT/.keys"
cp "$KEYFILE" "$REPO_ROOT/.keys/$HOSTNAME-disk.key"
chmod 600 "$REPO_ROOT/.keys/$HOSTNAME-disk.key"

# Run nixos-anywhere in phases so we can set up the /nix bind mount between
# partitioning and installation. Without this, the Nix store goes onto the
# tmpfs root and hits "No space left on device".

# Phase 1: Boot into kexec installer and partition/format/mount disks
echo "Phase 1: Partitioning and formatting disks..."
nix run github:nix-community/nixos-anywhere -- \
    --phases kexec,disko \
    --flake "$REPO_ROOT#$HOSTNAME" \
    --target-host "$TARGET" \
    --disk-encryption-keys /tmp/secret.key "$KEYFILE" \
    $EXTRA_ARGS

# Phase 2: Set up /nix bind mount so the store writes to persistent storage
echo "Phase 2: Setting up /nix bind mount on persistent storage..."
ssh "$TARGET" 'mkdir -p /mnt/persist/nix && mkdir -p /mnt/nix && mount --bind /mnt/persist/nix /mnt/nix'

# Phase 3: Install NixOS (Nix store now goes to ext4, not tmpfs)
echo "Phase 3: Installing NixOS..."
nix run github:nix-community/nixos-anywhere -- \
    --phases install \
    --flake "$REPO_ROOT#$HOSTNAME" \
    --target-host "$TARGET" \
    --disk-encryption-keys /tmp/secret.key "$KEYFILE" \
    $EXTRA_ARGS

# Phase 4: Copy encryption keyfile to /boot on the target
echo "Phase 4: Copying encryption keyfile to target..."
ssh "$TARGET" 'mkdir -p /mnt/boot/secrets && chmod 700 /mnt/boot/secrets'
scp "$KEYFILE" "$TARGET:/mnt/boot/secrets/disk.key"
ssh "$TARGET" 'chmod 600 /mnt/boot/secrets/disk.key'

# Phase 5: Fetch generated hardware-config
# (nixos-generate-config probes for btrfs on all mounts, so it may emit
# a harmless "not a btrfs filesystem" error)
echo "Phase 5: Fetching hardware-configuration.nix..."
ssh "$TARGET" 'nixos-generate-config --no-filesystems --show-hardware-config > /tmp/hw.nix 2>/dev/null'
scp "$TARGET:/tmp/hw.nix" "$REPO_ROOT/hosts/$HOSTNAME/hardware-configuration.nix"

echo ""
echo "======================================"
echo "Deployment complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. Review hosts/$HOSTNAME/hardware-configuration.nix"
echo "  2. Reboot and verify automatic LUKS unlock:"
echo "     ssh $TARGET 'reboot'"
echo ""
echo "Encryption keyfile saved to: $REPO_ROOT/.keys/$HOSTNAME-disk.key"
echo "BACKUP THIS FILE SECURELY - you cannot decrypt /persist without it!"
echo ""
