#!/usr/bin/env bash
set -euo pipefail

# nixos-anywhere deployment wrapper with encryption support
# Supports tmpfs (LUKS+XFS+tmpfs root) and btrfs (LUKS+btrfs) profiles.
# Usage: ./scripts/deploy-nixos-anywhere.sh <hostname> <target-ip> [extra-args]

HOSTNAME="${1:-}"
TARGET="${2:-}"

if [[ -z $HOSTNAME || -z $TARGET ]]; then
  echo "Usage: $0 <hostname> <target-ip> [extra-args]"
  echo ""
  echo "Examples:"
  echo "  $0 thebeyond root@192.168.1.100"
  echo "  $0 calvard user@example.com --build-on-remote"
  exit 1
fi

shift 2
EXTRA_ARGS=("$@")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Dependency checks ---
for cmd in jq ssh-keygen ssh-to-age sops nix; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd"
    exit 1
  fi
done

# --- Detect host profile from Nix config ---
# Derives profile from the actual disko config:
#   tmpfs  = LUKS + XFS (or non-btrfs) with tmpfs root
#   btrfs  = LUKS + btrfs subvolumes
echo "Detecting deploy profile for $HOSTNAME..."
FLAKE_REF="$REPO_ROOT#nixosConfigurations.$HOSTNAME.config.disko.devices.disk.main.content.partitions"
HAS_LUKS=$(nix eval "$FLAKE_REF" --apply 'p: builtins.hasAttr "persist" p && p.persist.content.type == "luks"' 2>/dev/null) || {
  echo "Error: Could not evaluate disko config for '$HOSTNAME'."
  echo "Ensure the host exists in the flake and imports a disko profile."
  exit 1
}
if [[ $HAS_LUKS == "true" ]]; then
  HAS_BTRFS=$(nix eval "$FLAKE_REF" --apply 'p: p.persist.content.content.type == "btrfs"' 2>/dev/null) || HAS_BTRFS="false"
  if [[ $HAS_BTRFS == "true" ]]; then
    PROFILE="btrfs"
  else
    PROFILE="tmpfs"
  fi
else
  echo "Error: Unsupported disko profile (expected LUKS partition)."
  exit 1
fi
echo "  Profile: $PROFILE"

# Create temp directory for working copies of keys
KEYFILE_DIR=$(mktemp -d)
EXTRA_FILES_DIR=$(mktemp -d)
trap 'rm -rf "$KEYFILE_DIR" "$EXTRA_FILES_DIR"' EXIT

SSH_KEY="$KEYFILE_DIR/ssh_host_ed25519_key"
KEYS_DIR="$REPO_ROOT/.keys"

# Update keys.json host key registry
update_host_key_registry() {
  local name="$1"
  local pubkey_file="$2"
  local pubkey
  pubkey=$(cat "$pubkey_file")
  local json_file="$REPO_ROOT/lib/common/data/keys.json"

  jq --arg name "$name" --arg key "$pubkey" \
    '.hostKeys[$name] = $key' "$json_file" >"$json_file.tmp" &&
    mv "$json_file.tmp" "$json_file"
  echo "  Updated keys.json: hostKeys.$name"
}

# --- Encryption key setup ---
KEYFILE="$KEYFILE_DIR/disk.key"
if [[ -f "$KEYS_DIR/$HOSTNAME-disk.key" ]]; then
  echo "Using existing LUKS keyfile from .keys/$HOSTNAME-disk.key"
  cp "$KEYS_DIR/$HOSTNAME-disk.key" "$KEYFILE"
  chmod 600 "$KEYFILE"
else
  echo "Generating new LUKS encryption keyfile..."
  head -c 64 /dev/urandom | base64 -w0 >"$KEYFILE"
  chmod 600 "$KEYFILE"
fi

# --- SSH host key setup ---
if [[ -f "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key" ]]; then
  echo "Using existing SSH host key from .keys/$HOSTNAME-ssh_host_ed25519_key"
  cp "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key" "$SSH_KEY"
  cp "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key.pub" "$SSH_KEY.pub"
  chmod 600 "$SSH_KEY"
else
  echo "Generating new SSH host key..."
  ssh-keygen -t ed25519 -f "$SSH_KEY" -q -N ""
fi
update_host_key_registry "$HOSTNAME" "$SSH_KEY.pub"

# --- Deployment summary ---
echo ""
echo "======================================"
echo "nixos-anywhere Deployment"
echo "======================================"
echo "Host:       $HOSTNAME"
echo "Target:     $TARGET"
echo "Profile:    $PROFILE"
echo "Flake:      $REPO_ROOT#$HOSTNAME"
echo "Encryption: LUKS with keyfile"
echo "Extra args: ${EXTRA_ARGS[*]:-none}"
echo "======================================"
echo ""

# --- Destructive operation warning ---
echo "!!! WARNING: DESTRUCTIVE OPERATION !!!"
echo "This will DESTROY ALL DATA on the target disk, including any existing"
echo "filesystems with microVM guest data."
echo ""
read -p "Type '$HOSTNAME' to confirm data destruction: " -r
echo
if [[ $REPLY != "$HOSTNAME" ]]; then
  echo "Deployment cancelled."
  exit 1
fi

# Confirm deployment
read -p "Deploy $HOSTNAME to $TARGET? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled."
  exit 1
fi

# Clear any stale SSH host keys for the target (reinstalls generate new keys)
TARGET_HOST="${TARGET#*@}" # strip user@ prefix: "root@1.2.3.4" -> "1.2.3.4"
ssh-keygen -R "$TARGET_HOST" 2>/dev/null || true

# --- sops-nix integration: host age key ---
AGE_KEY=$(ssh-to-age <"$SSH_KEY.pub")
ANCHOR="&sv_$HOSTNAME"
echo "Derived age key: $AGE_KEY"

SOPS_FILE="$REPO_ROOT/.sops.yaml"
if grep -q "$ANCHOR" "$SOPS_FILE"; then
  EXISTING_KEY=$(grep "$ANCHOR" "$SOPS_FILE" | sed 's/.*'"$ANCHOR"' //')
  if [[ $EXISTING_KEY == "$AGE_KEY" ]]; then
    echo "  .sops.yaml already has correct key for $HOSTNAME, skipping update."
  else
    echo "  Updating $ANCHOR in .sops.yaml..."
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

# Re-encrypt host secrets with the updated key
SECRET_FILES=$(find "$REPO_ROOT/hosts/$HOSTNAME/secrets/" -name '*.yaml' 2>/dev/null || true)
if [[ -n $SECRET_FILES ]]; then
  echo "Re-encrypting secrets for $HOSTNAME..."
  echo "$SECRET_FILES" | while read -r f; do
    echo "  sops updatekeys: $f"
    sops updatekeys --yes "$f"
  done
else
  echo "No host-level secret files found for $HOSTNAME, skipping re-encryption."
fi

# --- Guest setup (microVM + Incus) via setup-guest.sh ---
SETUP_GUEST="$REPO_ROOT/scripts/setup-guest.sh"
GUEST_DIR="$REPO_ROOT/hosts/$HOSTNAME/microvm/guests"
INCUS_GUEST_DIR="$REPO_ROOT/hosts/$HOSTNAME/incus/guests"
INCUS_GUESTS=()

if [[ -d $GUEST_DIR ]]; then
  echo ""
  echo "Setting up microVM guests..."
  for guest_path in "$GUEST_DIR"/*/; do
    [[ -d $guest_path ]] || continue
    guest="$(basename "$guest_path")"
    echo "  Guest: $guest"
    "$SETUP_GUEST" "$HOSTNAME" "$guest" --output-dir "$EXTRA_FILES_DIR"
  done
fi

if [[ -d $INCUS_GUEST_DIR ]]; then
  echo ""
  echo "Setting up Incus guests..."
  for guest_path in "$INCUS_GUEST_DIR"/*/; do
    [[ -d $guest_path ]] || continue
    guest="$(basename "$guest_path")"
    echo "  Guest: $guest"
    INCUS_GUESTS+=("$guest")
    "$SETUP_GUEST" "$HOSTNAME" "$guest" --output-dir "$EXTRA_FILES_DIR"
  done
fi

# Save host keys to .keys/ for backup (gitignored)
mkdir -p "$KEYS_DIR"
if [[ ! -f "$KEYS_DIR/$HOSTNAME-disk.key" ]]; then
  cp "$KEYFILE" "$KEYS_DIR/$HOSTNAME-disk.key"
  chmod 600 "$KEYS_DIR/$HOSTNAME-disk.key"
  echo "Saved new disk key to .keys/$HOSTNAME-disk.key"
fi
if [[ ! -f "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key" ]]; then
  cp "$SSH_KEY" "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key"
  cp "$SSH_KEY.pub" "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key.pub"
  chmod 600 "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key"
  echo "Saved new SSH key to .keys/$HOSTNAME-ssh_host_ed25519_key"
fi

# --- SSH host certificate signing ---
CA_KEY="$KEYS_DIR/ssh_host_ca_key"
CERTS_DIR="$REPO_ROOT/lib/common/data/host-certs"
UNSIGNED_HOSTS=()
ALL_HOST_DOMAINS=""

sign_host_cert() {
  local name="$1"
  local pubkey_file="$2"

  # Fetch domains once and cache
  if [[ -z $ALL_HOST_DOMAINS ]]; then
    ALL_HOST_DOMAINS=$(nix eval "$REPO_ROOT#lib.common.data.network.allHostDomains" --json)
  fi

  local principals
  principals=$(echo "$ALL_HOST_DOMAINS" | jq -r --arg h "$name" '.[$h] // [] | join(",")')
  if [[ -z $principals ]]; then
    echo "  $name: not in network registry, skipping certificate"
    UNSIGNED_HOSTS+=("$name")
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  cp "$pubkey_file" "$tmpdir/$name.pub"
  if ssh-keygen -s "$CA_KEY" -I "$name" -h -n "$principals" -V "+731d" -z "$(date +%s)" "$tmpdir/$name.pub" 2>/dev/null; then
    mkdir -p "$CERTS_DIR"
    mv "$tmpdir/$name-cert.pub" "$CERTS_DIR/$name-cert.pub"
    echo "  Signed host certificate: $name"
  else
    echo "  $name: ssh-keygen signing failed"
    UNSIGNED_HOSTS+=("$name")
  fi
  rm -rf "$tmpdir"
}

if [[ -f $CA_KEY ]]; then
  echo ""
  echo "Signing SSH host certificate for $HOSTNAME..."
  sign_host_cert "$HOSTNAME" "$SSH_KEY.pub"
  # Guest certificates are signed by setup-guest.sh
else
  echo ""
  echo "WARNING: SSH host CA key not found at $CA_KEY"
  echo "Skipping automatic host certificate signing."
  echo ""
  echo "To sign host certificates manually after deployment, run:"
  echo "  nix run .#ssh-host-cert-sign -- --sign $HOSTNAME"
  UNSIGNED_HOSTS+=("$HOSTNAME")
fi

# Prepare extra-files directory with SSH host key for nixos-anywhere
# All parent hosts use impermanence with SSH keys persisted at /persist/etc/ssh/
mkdir -p "$EXTRA_FILES_DIR/persist/etc/ssh"
cp "$SSH_KEY" "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key"
cp "$SSH_KEY.pub" "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key.pub"
chmod 600 "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key"
chmod 644 "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key.pub"

# Place LUKS keyfile in extra-files so it's installed with the system
# (avoids post-install SSH which can fail in the kexec environment)
mkdir -p "$EXTRA_FILES_DIR/boot/secrets"
chmod 700 "$EXTRA_FILES_DIR/boot/secrets"
cp "$KEYFILE" "$EXTRA_FILES_DIR/boot/secrets/disk.key"
chmod 600 "$EXTRA_FILES_DIR/boot/secrets/disk.key"

# ====================================================================
# Deployment phases (profile-dependent)
# ====================================================================

# Phase 1: Boot into kexec installer and partition/format/mount disks
echo "Phase 1: Partitioning and formatting disks..."
nix run github:nix-community/nixos-anywhere -- \
  --phases kexec,disko \
  --flake "$REPO_ROOT#$HOSTNAME" \
  --target-host "$TARGET" \
  --disk-encryption-keys /tmp/secret.key "$KEYFILE" \
  "${EXTRA_ARGS[@]}"

if [[ $PROFILE == "tmpfs" ]]; then
  # Phase 2 (tmpfs): Set up /nix bind mount so the store writes to persistent storage
  echo "Phase 2: Setting up /nix bind mount on persistent storage..."
  ssh "$TARGET" 'mkdir -p /mnt/persist/nix && mkdir -p /mnt/nix && mount --bind /mnt/persist/nix /mnt/nix'

elif [[ $PROFILE == "btrfs" ]]; then
  # Phase 2 (btrfs): Create @blank snapshot for impermanence rollback
  # btrfs subvolumes handle /nix natively (@nix mounted at /nix), so no bind mount needed
  echo "Phase 2: Creating @blank snapshot for btrfs impermanence..."
  ssh "$TARGET" 'mkdir -p /tmp/btrfs-root && mount /dev/mapper/cryptroot /tmp/btrfs-root -o subvolid=5 && btrfs subvolume snapshot -r /tmp/btrfs-root/@root /tmp/btrfs-root/@blank && umount /tmp/btrfs-root'
fi

# Phase 3: Install NixOS (with extra-files for SSH keys and guest dirs)
echo "Phase 3: Installing NixOS..."
nix run github:nix-community/nixos-anywhere -- \
  --phases install \
  --extra-files "$EXTRA_FILES_DIR" \
  --flake "$REPO_ROOT#$HOSTNAME" \
  --target-host "$TARGET" \
  --disk-encryption-keys /tmp/secret.key "$KEYFILE" \
  "${EXTRA_ARGS[@]}"

# Disk key and guest directory ownership are handled without post-install SSH:
# - Disk key: placed via --extra-files at /boot/secrets/disk.key
# - Guest dirs: systemd-tmpfiles rules in modules/common/microvm.nix

echo ""
echo "======================================"
echo "Deployment complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. Reboot into the installed system:"
echo "     ssh $TARGET 'reboot'"
echo "  2. Fetch the hardware config from the running system:"
echo "     ssh $TARGET 'nixos-generate-config --no-filesystems --show-hardware-config' > hosts/$HOSTNAME/hardware-configuration.nix"
echo "  3. Review hosts/$HOSTNAME/hardware-configuration.nix"
echo "  4. Commit .sops.yaml + hardware-configuration.nix changes"
echo "  5. Verify automatic LUKS unlock + sops secrets:"
echo "     ssh $TARGET 'systemctl status sops-nix && ls /run/secrets/'"
if [[ ${#INCUS_GUESTS[@]} -gt 0 ]]; then
  echo "  Incus guests (${INCUS_GUESTS[*]}) have SSH keys pre-placed in /persist/guests/*/static/"
  echo "  They will boot with keys available via the /static bind mount — no post-boot setup needed."
fi

echo ""
echo "Keys in $REPO_ROOT/.keys/ (gitignored):"
echo "  $HOSTNAME-disk.key                  — LUKS encryption key"
echo "  $HOSTNAME-ssh_host_ed25519_key      — SSH host private key"
echo "  $HOSTNAME-ssh_host_ed25519_key.pub  — SSH host public key"

if [[ ${#UNSIGNED_HOSTS[@]} -gt 0 ]]; then
  echo ""
  echo "Unsigned SSH host certificates:"
  echo "  The following hosts need host certificates signed manually:"
  for h in "${UNSIGNED_HOSTS[@]}"; do
    echo "    nix run .#ssh-host-cert-sign -- --sign $h"
  done
  echo ""
  echo "  Or sign all at once:"
  echo "    nix run .#ssh-host-cert-sign -- --sign-all"
  echo ""
  echo "  Then commit the certificates and rebuild the host(s)."
fi
echo ""
