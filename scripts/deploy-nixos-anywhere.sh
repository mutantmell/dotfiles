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
    echo "  $0 yggdrasil root@192.168.1.100"
    echo "  $0 vanaheim user@example.com --build-on-remote"
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
dd if=/dev/urandom of="$KEYFILE" bs=4096 count=1 2>/dev/null
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

# Save keyfile to repo for later use (gitignored)
mkdir -p "$REPO_ROOT/.keys"
cp "$KEYFILE" "$REPO_ROOT/.keys/$HOSTNAME-disk.key"
chmod 600 "$REPO_ROOT/.keys/$HOSTNAME-disk.key"

# Run nixos-anywhere with encryption
nix run github:nix-community/nixos-anywhere -- \
    --flake "$REPO_ROOT#$HOSTNAME" \
    --target-host "$TARGET" \
    --disk-encryption-keys /tmp/secret.key "$KEYFILE" \
    $EXTRA_ARGS

echo ""
echo "======================================"
echo "Deployment complete!"
echo "======================================"
echo ""
echo "IMPORTANT: Post-deployment steps required!"
echo ""
echo "1. Copy the encryption keyfile to /boot:"
echo "   scp $REPO_ROOT/.keys/$HOSTNAME-disk.key root@$TARGET:/boot/secrets/disk.key"
echo "   ssh root@$TARGET 'chmod 600 /boot/secrets/disk.key'"
echo ""
echo "2. Find the LUKS UUID and update configuration.nix:"
echo "   ssh root@$TARGET 'blkid | grep crypto_LUKS'"
echo "   # Update hosts/$HOSTNAME/configuration.nix with the UUID"
echo ""
echo "3. Regenerate hardware-config without filesystems:"
echo "   ssh root@$TARGET 'nixos-generate-config --no-filesystems --show-hardware-config > /tmp/hw.nix'"
echo "   scp root@$TARGET:/tmp/hw.nix $REPO_ROOT/hosts/$HOSTNAME/hardware-configuration.nix"
echo ""
echo "4. Rebuild the system with updated configuration:"
echo "   ssh root@$TARGET 'nixos-rebuild switch'"
echo ""
echo "5. Test autonomous reboot:"
echo "   ssh root@$TARGET 'reboot'"
echo "   # Wait for boot and verify automatic unlock worked"
echo ""
echo "Encryption keyfile saved to: $REPO_ROOT/.keys/$HOSTNAME-disk.key"
echo "BACKUP THIS FILE SECURELY - you cannot decrypt /persist without it!"
echo ""
