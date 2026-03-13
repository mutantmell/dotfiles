#!/usr/bin/env bash
set -euo pipefail

# nixos-anywhere deployment wrapper with encryption support
# Supports tmpfs (LUKS+XFS+tmpfs root), zfs (ZFS encrypted), and btrfs (LUKS+btrfs) profiles.
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

# --- Detect host profile from Nix config ---
# Derives profile from the actual disko config:
#   tmpfs  = LUKS + XFS (or non-btrfs) with tmpfs root
#   btrfs  = LUKS + btrfs subvolumes
#   zfs    = ZFS encrypted (no LUKS)
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
  PROFILE="zfs"
fi
echo "  Profile: $PROFILE"

# Read pinned microvm UID from the Nix config (defined in modules/common/microvm.nix)
NIXOS_CFG="$REPO_ROOT#nixosConfigurations.$HOSTNAME.config"
MICROVM_UID=$(nix eval "$NIXOS_CFG.common.microvm.uid" 2>/dev/null) || MICROVM_UID=""
KVM_GID=302 # Stable NixOS system GID for kvm group

# Create temp directory for working copies of keys
KEYFILE_DIR=$(mktemp -d)
EXTRA_FILES_DIR=$(mktemp -d)
trap 'rm -rf "$KEYFILE_DIR" "$EXTRA_FILES_DIR"' EXIT

SSH_KEY="$KEYFILE_DIR/ssh_host_ed25519_key"
INITRD_SSH_KEY="$KEYFILE_DIR/initrd_ssh_host_ed25519_key"
KEYS_DIR="$REPO_ROOT/.keys"

# --- Encryption key setup (profile-dependent) ---
if [[ $PROFILE == "tmpfs" || $PROFILE == "btrfs" ]]; then
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
elif [[ $PROFILE == "zfs" ]]; then
  KEYFILE="$KEYFILE_DIR/zfs.passphrase"
  if [[ -f "$KEYS_DIR/$HOSTNAME-zfs.passphrase" ]]; then
    echo "Using existing ZFS passphrase from .keys/$HOSTNAME-zfs.passphrase"
    cp "$KEYS_DIR/$HOSTNAME-zfs.passphrase" "$KEYFILE"
    chmod 600 "$KEYFILE"
  else
    echo "Generating new ZFS passphrase..."
    head -c 32 /dev/urandom | base64 -w0 >"$KEYFILE"
    chmod 600 "$KEYFILE"
  fi
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

# --- Initrd SSH host key setup (zfs profile only, for remote unlock) ---
if [[ $PROFILE == "zfs" ]]; then
  if [[ -f "$KEYS_DIR/$HOSTNAME-initrd_ssh_host_ed25519_key" ]]; then
    echo "Using existing initrd SSH host key from .keys/$HOSTNAME-initrd_ssh_host_ed25519_key"
    cp "$KEYS_DIR/$HOSTNAME-initrd_ssh_host_ed25519_key" "$INITRD_SSH_KEY"
    cp "$KEYS_DIR/$HOSTNAME-initrd_ssh_host_ed25519_key.pub" "$INITRD_SSH_KEY.pub"
    chmod 600 "$INITRD_SSH_KEY"
  else
    echo "Generating new initrd SSH host key (for ZFS remote unlock)..."
    ssh-keygen -t ed25519 -f "$INITRD_SSH_KEY" -q -N ""
  fi
fi

# --- Deployment summary ---
echo ""
echo "======================================"
echo "nixos-anywhere Deployment"
echo "======================================"
echo "Host:       $HOSTNAME"
echo "Target:     $TARGET"
echo "Profile:    $PROFILE"
echo "Flake:      $REPO_ROOT#$HOSTNAME"
if [[ $PROFILE == "tmpfs" || $PROFILE == "btrfs" ]]; then
  echo "Encryption: LUKS with keyfile"
elif [[ $PROFILE == "zfs" ]]; then
  echo "Encryption: ZFS native (passphrase)"
fi
echo "Extra args: ${EXTRA_ARGS[*]:-none}"
echo "======================================"
echo ""

# --- Destructive operation warning for zfs/btrfs profiles ---
if [[ $PROFILE == "zfs" || $PROFILE == "btrfs" ]]; then
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

# --- MicroVM guest setup ---
GUEST_DIR="$REPO_ROOT/hosts/$HOSTNAME/microvm/guests"
if [[ -d $GUEST_DIR ]]; then
  echo ""
  echo "Setting up microVM guests..."
  for guest_path in "$GUEST_DIR"/*/; do
    [[ -d $guest_path ]] || continue
    guest="$(basename "$guest_path")"
    echo "  Guest: $guest"

    GUEST_SSH_KEY="$KEYFILE_DIR/${guest}-ssh_host_ed25519_key"

    # Generate or reuse SSH host key
    if [[ -f "$KEYS_DIR/${guest}-ssh_host_ed25519_key" ]]; then
      echo "    Using existing SSH key from .keys/"
      cp "$KEYS_DIR/${guest}-ssh_host_ed25519_key" "$GUEST_SSH_KEY"
      cp "$KEYS_DIR/${guest}-ssh_host_ed25519_key.pub" "$GUEST_SSH_KEY.pub"
      chmod 600 "$GUEST_SSH_KEY"
    else
      echo "    Generating new SSH key..."
      ssh-keygen -t ed25519 -f "$GUEST_SSH_KEY" -q -N ""
    fi

    # Place SSH key in extra-files for virtiofs share
    mkdir -p "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh"
    cp "$GUEST_SSH_KEY" "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key"
    cp "$GUEST_SSH_KEY.pub" "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key.pub"
    chmod 600 "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key"
    chmod 644 "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key.pub"

    # Create images directory (microvm service creates volume images on first start)
    mkdir -p "$EXTRA_FILES_DIR/persist/guests/${guest}/images"

    # Derive age key and update .sops.yaml
    GUEST_AGE_KEY=$(ssh-to-age <"$GUEST_SSH_KEY.pub")
    GUEST_ANCHOR="&sv_${guest}"
    GUEST_ANCHOR_ESCAPED="${GUEST_ANCHOR//&/\\&}"

    if grep -q "$GUEST_ANCHOR" "$SOPS_FILE"; then
      EXISTING_GUEST_KEY=$(grep "$GUEST_ANCHOR" "$SOPS_FILE" | sed 's/.*'"$GUEST_ANCHOR"' //')
      if [[ $EXISTING_GUEST_KEY == "$GUEST_AGE_KEY" ]]; then
        echo "    .sops.yaml key already correct"
      else
        echo "    Updating $GUEST_ANCHOR in .sops.yaml..."
        sed -i "s|$GUEST_ANCHOR .*|$GUEST_ANCHOR_ESCAPED $GUEST_AGE_KEY|" "$SOPS_FILE"
      fi
    else
      echo "    WARNING: No $GUEST_ANCHOR anchor in .sops.yaml — add manually"
    fi

    # Re-encrypt guest secrets if they exist
    GUEST_SECRET_DIR="$GUEST_DIR/$guest/secrets"
    if [[ -d $GUEST_SECRET_DIR ]]; then
      GUEST_SECRET_FILES=$(find "$GUEST_SECRET_DIR" -name '*.yaml' 2>/dev/null || true)
      if [[ -n $GUEST_SECRET_FILES ]]; then
        echo "    Re-encrypting secrets..."
        echo "$GUEST_SECRET_FILES" | while read -r f; do
          echo "      sops updatekeys: $f"
          sops updatekeys --yes "$f"
        done
      fi
    fi

    # Backup keys
    mkdir -p "$KEYS_DIR"
    if [[ ! -f "$KEYS_DIR/${guest}-ssh_host_ed25519_key" ]]; then
      cp "$GUEST_SSH_KEY" "$KEYS_DIR/${guest}-ssh_host_ed25519_key"
      cp "$GUEST_SSH_KEY.pub" "$KEYS_DIR/${guest}-ssh_host_ed25519_key.pub"
      chmod 600 "$KEYS_DIR/${guest}-ssh_host_ed25519_key"
      echo "    Saved new SSH key to .keys/${guest}-ssh_host_ed25519_key"
    fi
  done
fi

# --- Incus guest setup ---
INCUS_GUEST_DIR="$REPO_ROOT/hosts/$HOSTNAME/incus/guests"
INCUS_GUESTS=()
if [[ -d $INCUS_GUEST_DIR ]]; then
  echo ""
  echo "Setting up Incus guests..."
  for guest_path in "$INCUS_GUEST_DIR"/*/; do
    [[ -d $guest_path ]] || continue
    guest="$(basename "$guest_path")"
    echo "  Guest: $guest"
    INCUS_GUESTS+=("$guest")

    GUEST_SSH_KEY="$KEYFILE_DIR/${guest}-ssh_host_ed25519_key"

    # Generate or reuse SSH host key
    if [[ -f "$KEYS_DIR/${guest}-ssh_host_ed25519_key" ]]; then
      echo "    Using existing SSH key from .keys/"
      cp "$KEYS_DIR/${guest}-ssh_host_ed25519_key" "$GUEST_SSH_KEY"
      cp "$KEYS_DIR/${guest}-ssh_host_ed25519_key.pub" "$GUEST_SSH_KEY.pub"
      chmod 600 "$GUEST_SSH_KEY"
    else
      echo "    Generating new SSH key..."
      ssh-keygen -t ed25519 -f "$GUEST_SSH_KEY" -q -N ""
    fi

    # Place SSH key in extra-files for static directory bind mount
    mkdir -p "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh"
    cp "$GUEST_SSH_KEY" "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key"
    cp "$GUEST_SSH_KEY.pub" "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key.pub"
    chmod 600 "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key"
    chmod 644 "$EXTRA_FILES_DIR/persist/guests/${guest}/static/etc/ssh/ssh_host_ed25519_key.pub"

    # Derive age key and update .sops.yaml
    GUEST_AGE_KEY=$(ssh-to-age <"$GUEST_SSH_KEY.pub")
    GUEST_ANCHOR="&sv_${guest}"
    GUEST_ANCHOR_ESCAPED="${GUEST_ANCHOR//&/\\&}"

    if grep -q "$GUEST_ANCHOR" "$SOPS_FILE"; then
      EXISTING_GUEST_KEY=$(grep "$GUEST_ANCHOR" "$SOPS_FILE" | sed 's/.*'"$GUEST_ANCHOR"' //')
      if [[ $EXISTING_GUEST_KEY == "$GUEST_AGE_KEY" ]]; then
        echo "    .sops.yaml key already correct"
      else
        echo "    Updating $GUEST_ANCHOR in .sops.yaml..."
        sed -i "s|$GUEST_ANCHOR .*|$GUEST_ANCHOR_ESCAPED $GUEST_AGE_KEY|" "$SOPS_FILE"
      fi
    else
      echo "    WARNING: No $GUEST_ANCHOR anchor in .sops.yaml — add manually"
    fi

    # Re-encrypt guest secrets if they exist
    GUEST_SECRET_DIR="$INCUS_GUEST_DIR/$guest/secrets"
    if [[ -d $GUEST_SECRET_DIR ]]; then
      GUEST_SECRET_FILES=$(find "$GUEST_SECRET_DIR" -name '*.yaml' 2>/dev/null || true)
      if [[ -n $GUEST_SECRET_FILES ]]; then
        echo "    Re-encrypting secrets..."
        echo "$GUEST_SECRET_FILES" | while read -r f; do
          echo "      sops updatekeys: $f"
          sops updatekeys --yes "$f"
        done
      fi
    fi

    # Backup keys
    mkdir -p "$KEYS_DIR"
    if [[ ! -f "$KEYS_DIR/${guest}-ssh_host_ed25519_key" ]]; then
      cp "$GUEST_SSH_KEY" "$KEYS_DIR/${guest}-ssh_host_ed25519_key"
      cp "$GUEST_SSH_KEY.pub" "$KEYS_DIR/${guest}-ssh_host_ed25519_key.pub"
      chmod 600 "$KEYS_DIR/${guest}-ssh_host_ed25519_key"
      echo "    Saved new SSH key to .keys/${guest}-ssh_host_ed25519_key"
    fi
  done
fi

# Save host keys to .keys/ for backup (gitignored)
mkdir -p "$KEYS_DIR"
if [[ $PROFILE == "tmpfs" || $PROFILE == "btrfs" ]]; then
  if [[ ! -f "$KEYS_DIR/$HOSTNAME-disk.key" ]]; then
    cp "$KEYFILE" "$KEYS_DIR/$HOSTNAME-disk.key"
    chmod 600 "$KEYS_DIR/$HOSTNAME-disk.key"
    echo "Saved new disk key to .keys/$HOSTNAME-disk.key"
  fi
elif [[ $PROFILE == "zfs" ]]; then
  if [[ ! -f "$KEYS_DIR/$HOSTNAME-zfs.passphrase" ]]; then
    cp "$KEYFILE" "$KEYS_DIR/$HOSTNAME-zfs.passphrase"
    chmod 600 "$KEYS_DIR/$HOSTNAME-zfs.passphrase"
    echo "Saved new ZFS passphrase to .keys/$HOSTNAME-zfs.passphrase"
  fi
fi
if [[ ! -f "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key" ]]; then
  cp "$SSH_KEY" "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key"
  cp "$SSH_KEY.pub" "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key.pub"
  chmod 600 "$KEYS_DIR/$HOSTNAME-ssh_host_ed25519_key"
  echo "Saved new SSH key to .keys/$HOSTNAME-ssh_host_ed25519_key"
fi
if [[ $PROFILE == "zfs" && ! -f "$KEYS_DIR/$HOSTNAME-initrd_ssh_host_ed25519_key" ]]; then
  cp "$INITRD_SSH_KEY" "$KEYS_DIR/$HOSTNAME-initrd_ssh_host_ed25519_key"
  cp "$INITRD_SSH_KEY.pub" "$KEYS_DIR/$HOSTNAME-initrd_ssh_host_ed25519_key.pub"
  chmod 600 "$KEYS_DIR/$HOSTNAME-initrd_ssh_host_ed25519_key"
  echo "Saved new initrd SSH key to .keys/$HOSTNAME-initrd_ssh_host_ed25519_key"
fi

# Prepare extra-files directory with SSH host key for nixos-anywhere
# All parent hosts use impermanence with SSH keys persisted at /persist/etc/ssh/
mkdir -p "$EXTRA_FILES_DIR/persist/etc/ssh"
cp "$SSH_KEY" "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key"
cp "$SSH_KEY.pub" "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key.pub"
chmod 600 "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key"
chmod 644 "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key.pub"

# Place initrd SSH key for zfs profile (ZFS remote unlock via SSH in initrd)
if [[ $PROFILE == "zfs" ]]; then
  cp "$INITRD_SSH_KEY" "$EXTRA_FILES_DIR/persist/etc/ssh/initrd_ssh_host_ed25519_key"
  cp "$INITRD_SSH_KEY.pub" "$EXTRA_FILES_DIR/persist/etc/ssh/initrd_ssh_host_ed25519_key.pub"
  chmod 600 "$EXTRA_FILES_DIR/persist/etc/ssh/initrd_ssh_host_ed25519_key"
  chmod 644 "$EXTRA_FILES_DIR/persist/etc/ssh/initrd_ssh_host_ed25519_key.pub"
fi

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

elif [[ $PROFILE == "zfs" ]]; then
  # Phase 2 (zfs): Set ZFS keylocation to prompt for interactive unlock on boot
  # ZFS datasets handle /nix natively (dataset local/nix mounted at /nix), so no bind mount needed
  echo "Phase 2: Setting ZFS keylocation to prompt..."
  ssh "$TARGET" 'zfs set keylocation=prompt zroot'
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

if [[ $PROFILE == "tmpfs" ]]; then
  # Phase 4 (tmpfs): Copy encryption keyfile to /boot on the target
  echo "Phase 4: Copying encryption keyfile to target..."
  ssh "$TARGET" 'mkdir -p /mnt/boot/secrets && chmod 700 /mnt/boot/secrets'
  scp "$KEYFILE" "$TARGET:/mnt/boot/secrets/disk.key"
  ssh "$TARGET" 'chmod 600 /mnt/boot/secrets/disk.key'

elif [[ $PROFILE == "btrfs" ]]; then
  # Phase 4 (btrfs): Copy LUKS keyfile + fix guest directory ownership
  echo "Phase 4: Copying encryption keyfile to target..."
  ssh "$TARGET" 'mkdir -p /mnt/boot/secrets && chmod 700 /mnt/boot/secrets'
  scp "$KEYFILE" "$TARGET:/mnt/boot/secrets/disk.key"
  ssh "$TARGET" 'chmod 600 /mnt/boot/secrets/disk.key'

  if [[ -z $MICROVM_UID ]]; then
    echo "ERROR: Could not determine microvm UID from Nix config."
    echo "Falling back to default UID 300 (pinned in modules/common/microvm.nix)."
    MICROVM_UID=300
  fi
  echo "Phase 4: Fixing guest directory ownership (microvm=$MICROVM_UID, kvm=$KVM_GID)..."
  ssh "$TARGET" bash -c "'
        for guest_dir in /mnt/persist/guests/*/; do
            [ -d \"\$guest_dir/static\" ] && chown -R root:root \"\$guest_dir/static\"
            [ -d \"\$guest_dir/images\" ] && chown ${MICROVM_UID}:${KVM_GID} \"\$guest_dir/images\"
        done
    '"

elif [[ $PROFILE == "zfs" ]]; then
  # Phase 4 (zfs): Fix ownership on guest directories
  if [[ -z $MICROVM_UID ]]; then
    echo "ERROR: Could not determine microvm UID from Nix config."
    echo "Falling back to default UID 300 (pinned in modules/common/microvm.nix)."
    MICROVM_UID=300
  fi
  echo "Phase 4: Fixing guest directory ownership (microvm=$MICROVM_UID, kvm=$KVM_GID)..."
  ssh "$TARGET" bash -c "'
        for guest_dir in /mnt/persist/guests/*/; do
            [ -d \"\$guest_dir/static\" ] && chown -R root:root \"\$guest_dir/static\"
            [ -d \"\$guest_dir/images\" ] && chown ${MICROVM_UID}:${KVM_GID} \"\$guest_dir/images\"
        done
    '"
fi

# Phase 5: Fetch generated hardware-config
echo "Phase 5: Fetching hardware-configuration.nix..."
ssh "$TARGET" 'nixos-generate-config --no-filesystems --show-hardware-config > /tmp/hw.nix'
scp "$TARGET:/tmp/hw.nix" "$REPO_ROOT/hosts/$HOSTNAME/hardware-configuration.nix"

echo ""
echo "======================================"
echo "Deployment complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. Review hosts/$HOSTNAME/hardware-configuration.nix"
echo "  2. Commit .sops.yaml changes (age keys were updated)"

if [[ $PROFILE == "tmpfs" || $PROFILE == "btrfs" ]]; then
  echo "  3. Reboot and verify automatic LUKS unlock + sops secrets:"
  echo "     ssh $TARGET 'reboot'"
  echo "     ssh $TARGET 'systemctl status sops-nix && ls /run/secrets/'"
  if [[ $PROFILE == "btrfs" && ${#INCUS_GUESTS[@]} -gt 0 ]]; then
    echo "  Incus guests (${INCUS_GUESTS[*]}) have SSH keys pre-placed in /persist/guests/*/static/"
    echo "  They will boot with keys available via the /static bind mount — no post-boot setup needed."
  fi
elif [[ $PROFILE == "zfs" ]]; then
  echo "  3. Reboot — you'll need to SSH to port 2222 for ZFS unlock:"
  echo "     ssh $TARGET 'reboot'"
  echo "     ssh -p 2222 $TARGET_HOST  # then enter ZFS passphrase"
  echo "  4. After boot, verify sops secrets:"
  echo "     ssh $TARGET 'systemctl status sops-nix && ls /run/secrets/'"
  if [[ ${#INCUS_GUESTS[@]} -gt 0 ]]; then
    echo "  Incus guests (${INCUS_GUESTS[*]}) have SSH keys pre-placed in /persist/guests/*/static/"
    echo "  They will boot with keys available via the /static bind mount — no post-boot setup needed."
  fi
fi

echo ""
echo "Keys in $REPO_ROOT/.keys/ (gitignored):"
if [[ $PROFILE == "tmpfs" || $PROFILE == "btrfs" ]]; then
  echo "  $HOSTNAME-disk.key                  — LUKS encryption key"
elif [[ $PROFILE == "zfs" ]]; then
  echo "  $HOSTNAME-zfs.passphrase            — ZFS encryption passphrase"
fi
echo "  $HOSTNAME-ssh_host_ed25519_key      — SSH host private key"
echo "  $HOSTNAME-ssh_host_ed25519_key.pub  — SSH host public key"
if [[ $PROFILE == "zfs" ]]; then
  echo "  $HOSTNAME-initrd_ssh_host_ed25519_key      — Initrd SSH key (ZFS remote unlock)"
  echo "  $HOSTNAME-initrd_ssh_host_ed25519_key.pub  — Initrd SSH public key"
fi
echo ""
