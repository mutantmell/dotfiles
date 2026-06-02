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
for cmd in jq ssh-keygen age-keygen sops nix openssl passage; do
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

# Create temp directories for working copies of keys. Prefer tmpfs (/dev/shm)
# so private key material — disk key, SSH host/CA keys, X5C CA key, enrollment
# keys, and the age identity — never lands on persistent storage; fall back to
# $TMPDIR if /dev/shm is unavailable.
KEYFILE_DIR=$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)
EXTRA_FILES_DIR=$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)
trap 'rm -rf "$KEYFILE_DIR" "$EXTRA_FILES_DIR"' EXIT

SSH_KEY="$KEYFILE_DIR/ssh_host_ed25519_key"

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
if passage show "hosts/$HOSTNAME/disk.key" >"$KEYFILE" 2>/dev/null; then
  chmod 600 "$KEYFILE"
  echo "Using existing LUKS keyfile from passage:hosts/$HOSTNAME/disk.key"
else
  echo "Generating new LUKS encryption keyfile..."
  head -c 64 /dev/urandom | base64 -w0 >"$KEYFILE"
  chmod 600 "$KEYFILE"
fi

# --- SSH host key setup ---
if passage show "hosts/$HOSTNAME/ssh_host_ed25519_key" >"$SSH_KEY" 2>/dev/null; then
  chmod 600 "$SSH_KEY"
  ssh-keygen -y -f "$SSH_KEY" >"$SSH_KEY.pub"
  echo "Using existing SSH host key from passage:hosts/$HOSTNAME/ssh_host_ed25519_key"
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

# --- sops-nix integration: host PQC age identity ---
# The host decrypts its sops secrets with a native age hybrid post-quantum
# identity (ML-KEM-768 + X25519), independent of the SSH host key above.
# Reuse the identity from passage if present, else generate a fresh one.
PQC_KEY="$KEYFILE_DIR/age.key"
if passage show "hosts/$HOSTNAME/age.key" >"$PQC_KEY" 2>/dev/null; then
  chmod 600 "$PQC_KEY"
  echo "Using existing PQC age identity from passage:hosts/$HOSTNAME/age.key"
else
  rm -f "$PQC_KEY"
  echo "Generating new PQC age identity..."
  age-keygen -pq -o "$PQC_KEY" 2>/dev/null
  chmod 600 "$PQC_KEY"
fi
AGE_KEY=$(age-keygen -y "$PQC_KEY")
ANCHOR="&sv_$HOSTNAME"
echo "Host age recipient: $AGE_KEY"

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

# Re-encrypt host secrets with the updated key.
# NOTE: age refuses to encrypt to mixed classical + post-quantum recipients,
# so this host's creation_rule in .sops.yaml must reference the PQ admin
# anchor (*admin) alongside *sv_<host> — not the classical *ad_denai.
# `sops updatekeys` will error on a mixed rule; fix the rule and re-run.
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

# --- Store new keys in passage ---
if ! passage show "hosts/$HOSTNAME/disk.key" >/dev/null 2>&1; then
  passage insert -m -f "hosts/$HOSTNAME/disk.key" <"$KEYFILE"
  echo "Stored disk key in passage:hosts/$HOSTNAME/disk.key"
fi
if ! passage show "hosts/$HOSTNAME/ssh_host_ed25519_key" >/dev/null 2>&1; then
  passage insert -m -f "hosts/$HOSTNAME/ssh_host_ed25519_key" <"$SSH_KEY"
  echo "Stored SSH key in passage:hosts/$HOSTNAME/ssh_host_ed25519_key"
fi
if ! passage show "hosts/$HOSTNAME/age.key" >/dev/null 2>&1; then
  passage insert -m -f "hosts/$HOSTNAME/age.key" <"$PQC_KEY"
  echo "Stored PQC age identity in passage:hosts/$HOSTNAME/age.key"
fi

# --- Fleet enrollment key setup ---
ENROLLMENT_KEY="$KEYFILE_DIR/fleet_enrollment_key"
ENROLLMENT_PUB="$KEYFILE_DIR/fleet_enrollment_key.pub"

if passage show "hosts/$HOSTNAME/fleet_enrollment_key" >"$ENROLLMENT_KEY" 2>/dev/null; then
  chmod 600 "$ENROLLMENT_KEY"
  openssl pkey -in "$ENROLLMENT_KEY" -pubout -out "$ENROLLMENT_PUB" 2>/dev/null
  echo "Using existing fleet enrollment key from passage:hosts/$HOSTNAME/fleet_enrollment_key"
else
  echo "Generating new fleet enrollment key..."
  openssl genpkey -algorithm ED25519 -out "$ENROLLMENT_KEY"
  openssl pkey -in "$ENROLLMENT_KEY" -pubout -out "$ENROLLMENT_PUB"
  chmod 600 "$ENROLLMENT_KEY"
fi

jq --arg name "$HOSTNAME" --arg key "$(cat "$ENROLLMENT_PUB")" \
  '.fleetEnrollmentKeys[$name] = $key' "$REPO_ROOT/lib/common/data/keys.json" \
  >"$REPO_ROOT/lib/common/data/keys.json.tmp" &&
  mv "$REPO_ROOT/lib/common/data/keys.json.tmp" "$REPO_ROOT/lib/common/data/keys.json"
echo "  Updated keys.json: fleetEnrollmentKeys.$HOSTNAME"

if ! passage show "hosts/$HOSTNAME/fleet_enrollment_key" >/dev/null 2>&1; then
  passage insert -m -f "hosts/$HOSTNAME/fleet_enrollment_key" <"$ENROLLMENT_KEY"
  echo "Stored enrollment key in passage:hosts/$HOSTNAME/fleet_enrollment_key"
fi

# --- SSH host certificate signing ---
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

  if [[ -f "$CERTS_DIR/$name-cert.pub" ]]; then
    echo "  $name: SSH host certificate already exists, skipping"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  cp "$pubkey_file" "$tmpdir/$name.pub"
  if ssh-keygen -s "$SSH_CA_KEY" -I "$name" -h -n "$principals" -V "+731d" -z "$(date +%s)" "$tmpdir/$name.pub" 2>/dev/null; then
    mkdir -p "$CERTS_DIR"
    mv "$tmpdir/$name-cert.pub" "$CERTS_DIR/$name-cert.pub"
    echo "  Signed host certificate: $name"
  else
    echo "  $name: ssh-keygen signing failed"
    UNSIGNED_HOSTS+=("$name")
  fi
  rm -rf "$tmpdir"
}

SSH_CA_KEY="$KEYFILE_DIR/ssh_host_ca_key"
echo ""
if passage show "pki/ssh_host_ca_key" >"$SSH_CA_KEY" 2>/dev/null; then
  chmod 600 "$SSH_CA_KEY"
  echo "Signing SSH host certificate for $HOSTNAME..."
  sign_host_cert "$HOSTNAME" "$SSH_KEY.pub"
  # Guest certificates are signed by setup-guest.sh
  # Stage new cert so flake eval (git-tracked only) picks it up before install.
  if [[ -f "$CERTS_DIR/$HOSTNAME-cert.pub" ]]; then
    git -C "$REPO_ROOT" add "$CERTS_DIR/$HOSTNAME-cert.pub" 2>/dev/null || true
  fi
else
  echo "SSH host CA key not found in passage (pki/ssh_host_ca_key) — skipping certificate signing."
  echo "  To sign manually: nix run .#ssh-host-cert-sign -- --sign $HOSTNAME"
  UNSIGNED_HOSTS+=("$HOSTNAME")
fi

# --- Fleet enrollment certificate signing ---
X5C_CA_CRT="$REPO_ROOT/lib/common/data/pki/fleet_x5c_ca.crt"
UNSIGNED_ENROLLMENT_HOSTS=()

if [[ -f "$REPO_ROOT/lib/common/data/fleet-x5c-certs/$HOSTNAME.crt" ]]; then
  echo ""
  echo "Fleet enrollment certificate already exists for $HOSTNAME, skipping."
  echo "  To re-sign: nix run .#fleet-x5c-cert-sign -- --sign $HOSTNAME"
else
  X5C_CA_KEY="$KEYFILE_DIR/fleet_x5c_ca_key"
  echo ""
  if [[ -f $X5C_CA_CRT ]] && passage show "pki/fleet_x5c_ca_key" >"$X5C_CA_KEY" 2>/dev/null; then
    chmod 600 "$X5C_CA_KEY"
    echo "Signing fleet enrollment certificate for $HOSTNAME..."
    if nix run "$REPO_ROOT#fleet-x5c-cert-sign" -- --sign "$HOSTNAME" --ca-key "$X5C_CA_KEY" 2>/dev/null; then
      echo "  Signed enrollment certificate: $HOSTNAME"
      # Stage new cert so flake eval (git-tracked only) picks it up before install.
      git -C "$REPO_ROOT" add "$REPO_ROOT/lib/common/data/fleet-x5c-certs/$HOSTNAME.crt" 2>/dev/null || true
    else
      echo "  fleet-x5c-cert-sign failed"
      UNSIGNED_ENROLLMENT_HOSTS+=("$HOSTNAME")
    fi
  else
    echo "Fleet X5C CA not yet available — skipping enrollment cert signing."
    echo "  After generating the CA, run: nix run .#fleet-x5c-cert-sign -- --sign $HOSTNAME"
    UNSIGNED_ENROLLMENT_HOSTS+=("$HOSTNAME")
  fi
fi

# Prepare extra-files directory with SSH host key for nixos-anywhere
# All parent hosts use impermanence with SSH keys persisted at /persist/etc/ssh/
mkdir -p "$EXTRA_FILES_DIR/persist/etc/ssh"
cp "$SSH_KEY" "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key"
cp "$SSH_KEY.pub" "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key.pub"
chmod 600 "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key"
chmod 644 "$EXTRA_FILES_DIR/persist/etc/ssh/ssh_host_ed25519_key.pub"

# sops-nix PQC identity — persisted at /persist/var/lib/sops-nix/key.txt and
# bind-mounted to /var/lib/sops-nix/key.txt by impermanence (see
# modules/common/impermanence.nix). sops.nix reads it via age.keyFile.
mkdir -p "$EXTRA_FILES_DIR/persist/var/lib/sops-nix"
cp "$PQC_KEY" "$EXTRA_FILES_DIR/persist/var/lib/sops-nix/key.txt"
chmod 0400 "$EXTRA_FILES_DIR/persist/var/lib/sops-nix/key.txt"

# Fleet enrollment key — into impermanence persist path so it's available at
# /var/lib/fleet-tls/enrollment.key on first boot (via impermanence bind mount).
# fleet-enrollment-key.service skips via ConditionPathExists when key exists.
mkdir -p "$EXTRA_FILES_DIR/persist/var/lib/fleet-tls"
cp "$ENROLLMENT_KEY" "$EXTRA_FILES_DIR/persist/var/lib/fleet-tls/enrollment.key"
cp "$ENROLLMENT_PUB" "$EXTRA_FILES_DIR/persist/var/lib/fleet-tls/enrollment.pub"
chmod 600 "$EXTRA_FILES_DIR/persist/var/lib/fleet-tls/enrollment.key"
chmod 644 "$EXTRA_FILES_DIR/persist/var/lib/fleet-tls/enrollment.pub"

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
echo "Keys stored in passage store under hosts/$HOSTNAME/:"
echo "  disk.key                  — LUKS encryption key"
echo "  ssh_host_ed25519_key      — SSH host private key"
echo "  age.key                   — sops-nix PQC decryption identity"
echo "  fleet_enrollment_key      — fleet TLS enrollment private key"

if [[ ${#UNSIGNED_ENROLLMENT_HOSTS[@]} -gt 0 ]]; then
  echo ""
  echo "Unsigned fleet enrollment certificates:"
  for h in "${UNSIGNED_ENROLLMENT_HOSTS[@]}"; do
    echo "    nix run .#fleet-x5c-cert-sign -- --sign $h"
  done
  echo "  Commit certs and redeploy for fleet-tls-bootstrap to succeed."
fi

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
