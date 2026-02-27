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

# Create temp directory for generated keys
KEYFILE_DIR=$(mktemp -d)
EXTRA_FILES_DIR=$(mktemp -d)
trap "rm -rf $KEYFILE_DIR $EXTRA_FILES_DIR" EXIT

# Generate LUKS encryption keyfile
KEYFILE="$KEYFILE_DIR/disk.key"
echo "Generating LUKS encryption keyfile..."
# Generate a text-safe key (base64) so it survives bash command substitution
# in disko's passwordFile handling and can be stored in a password manager.
head -c 64 /dev/urandom | base64 -w0 > "$KEYFILE"
chmod 600 "$KEYFILE"

# Generate SSH host key for sops-nix secret decryption
SSH_KEY="$KEYFILE_DIR/ssh_host_ed25519_key"
echo "Generating SSH host key..."
ssh-keygen -t ed25519 -f "$SSH_KEY" -q -N ""

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

# Derive age key from the SSH host key for sops integration
AGE_KEY=$(ssh-to-age < "$SSH_KEY.pub")
ANCHOR="&sv_$HOSTNAME"
echo "Derived age key: $AGE_KEY"

# Update .sops.yaml with the new age key
SOPS_FILE="$REPO_ROOT/.sops.yaml"
if grep -q "$ANCHOR" "$SOPS_FILE"; then
    EXISTING_KEY=$(grep "$ANCHOR" "$SOPS_FILE" | sed 's/.*'"$ANCHOR"' //')
    if [[ "$EXISTING_KEY" == "$AGE_KEY" ]]; then
        echo "  .sops.yaml already has correct key for $HOSTNAME, skipping update."
    else
        echo "  Updating $ANCHOR in .sops.yaml..."
        # Escape & in replacement string — sed treats bare & as "entire match"
        ANCHOR_ESCAPED="${ANCHOR//&/\\&}"
        sed -i "s|$ANCHOR .*|$ANCHOR_ESCAPED $AGE_KEY|" "$SOPS_FILE"
    fi
else
    echo ""
    echo "WARNING: No $ANCHOR anchor found in .sops.yaml."
    echo "You must manually add the following line to .sops.yaml keys section:"
    echo "  - $ANCHOR $AGE_KEY"
    echo "and add *sv_$HOSTNAME to the appropriate creation_rules."
    echo ""
fi

# Re-encrypt secrets for this host with the updated key
SECRET_FILES=$(find "$REPO_ROOT/hosts/" -path "*${HOSTNAME}*/secrets/*.yaml" 2>/dev/null || true)
if [[ -n "$SECRET_FILES" ]]; then
    echo "Re-encrypting secrets for $HOSTNAME..."
    echo "$SECRET_FILES" | while read -r f; do
        echo "  sops updatekeys: $f"
        sops updatekeys --yes "$f"
    done
else
    echo "No secret files found for $HOSTNAME, skipping re-encryption."
fi

# Save keys to repo for later use (gitignored)
mkdir -p "$REPO_ROOT/.keys"
cp "$KEYFILE" "$REPO_ROOT/.keys/$HOSTNAME-disk.key"
chmod 600 "$REPO_ROOT/.keys/$HOSTNAME-disk.key"
cp "$SSH_KEY" "$REPO_ROOT/.keys/$HOSTNAME-ssh_host_ed25519_key"
cp "$SSH_KEY.pub" "$REPO_ROOT/.keys/$HOSTNAME-ssh_host_ed25519_key.pub"
chmod 600 "$REPO_ROOT/.keys/$HOSTNAME-ssh_host_ed25519_key"

# Prepare extra-files directory with SSH host key for nixos-anywhere
# All parent hosts use impermanence with SSH keys persisted at /persist/etc/ssh/
mkdir -p "$EXTRA_FILES_DIR/persist/etc/ssh"
cp "$SSH_KEY" "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key"
cp "$SSH_KEY.pub" "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key.pub"
chmod 600 "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key"
chmod 644 "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key.pub"

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
# --extra-files places the pre-generated SSH host key into /persist/etc/ssh/
# so sops-nix can decrypt secrets on first boot.
echo "Phase 3: Installing NixOS..."
nix run github:nix-community/nixos-anywhere -- \
    --phases install \
    --extra-files "$EXTRA_FILES_DIR" \
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
echo "  2. Commit .sops.yaml changes (age key was updated for $HOSTNAME)"
echo "  3. Reboot and verify automatic LUKS unlock + sops secrets:"
echo "     ssh $TARGET 'reboot'"
echo "     ssh $TARGET 'systemctl status sops-nix && ls /run/secrets/'"
echo ""
echo "Keys saved to $REPO_ROOT/.keys/ (gitignored):"
echo "  $HOSTNAME-disk.key                  — LUKS encryption key"
echo "  $HOSTNAME-ssh_host_ed25519_key      — SSH host private key"
echo "  $HOSTNAME-ssh_host_ed25519_key.pub  — SSH host public key"
echo "BACKUP THESE FILES SECURELY!"
echo ""
