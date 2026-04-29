#!/usr/bin/env bash
set -euo pipefail

# Set up SSH keys and fleet enrollment key for a VM guest.
# Keys are read from and stored to the passage password store.
# Can place files into a local directory (for nixos-anywhere --extra-files)
# or deploy directly to a running host via SSH.
#
# Usage:
#   ./scripts/setup-guest.sh <parent-hostname> <guest-name> --output-dir <dir>
#   ./scripts/setup-guest.sh <parent-hostname> <guest-name> --target <ssh-host>

PARENT="${1:-}"
GUEST="${2:-}"

if [[ -z $PARENT || -z $GUEST ]]; then
  echo "Usage: $0 <parent-hostname> <guest-name> [--output-dir <dir> | --target <ssh-host>]"
  echo ""
  echo "Modes:"
  echo "  --output-dir <dir>    Place files in local directory (for nixos-anywhere)"
  echo "  --target <ssh-host>   Deploy files via SSH to a running host"
  echo "  (neither)             Only generate keys and update sops/keys.json"
  echo ""
  echo "Examples:"
  echo "  $0 erebonia roer --target root@erebonia"
  echo "  $0 erebonia roer --output-dir /tmp/extra-files"
  exit 1
fi

shift 2

OUTPUT_DIR=""
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --output-dir)
    OUTPUT_DIR="$2"
    shift 2
    ;;
  --target)
    TARGET="$2"
    shift 2
    ;;
  *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Dependency checks ---
for cmd in jq ssh-keygen ssh-to-age sops openssl passage; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd"
    exit 1
  fi
done

# --- Detect guest type (microvm or incus) ---
MICROVM_GUEST_DIR="$REPO_ROOT/hosts/$PARENT/microvm/guests/$GUEST"
INCUS_GUEST_DIR="$REPO_ROOT/hosts/$PARENT/incus/guests/$GUEST"

if [[ -d $MICROVM_GUEST_DIR ]]; then
  GUEST_TYPE="microvm"
  GUEST_SECRET_DIR="$MICROVM_GUEST_DIR/secrets"
elif [[ -d $INCUS_GUEST_DIR ]]; then
  GUEST_TYPE="incus"
  GUEST_SECRET_DIR="$INCUS_GUEST_DIR/secrets"
else
  echo "Error: Guest '$GUEST' not found under hosts/$PARENT/microvm/guests/ or hosts/$PARENT/incus/guests/"
  exit 1
fi
echo "Guest type: $GUEST_TYPE"

SOPS_FILE="$REPO_ROOT/.sops.yaml"

# Create temp directory for working copies of keys
KEYFILE_DIR=$(mktemp -d)
trap 'rm -rf "$KEYFILE_DIR"' EXIT

# --- Helper: update keys.json host key registry ---
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

# --- SSH key generation/reuse ---
GUEST_SSH_KEY="$KEYFILE_DIR/${GUEST}-ssh_host_ed25519_key"

if passage show "hosts/$GUEST/ssh_host_ed25519_key" > "$GUEST_SSH_KEY" 2>/dev/null; then
  chmod 600 "$GUEST_SSH_KEY"
  ssh-keygen -y -f "$GUEST_SSH_KEY" > "$GUEST_SSH_KEY.pub"
  echo "Using existing SSH key from passage:hosts/$GUEST/ssh_host_ed25519_key"
else
  echo "Generating new SSH key..."
  ssh-keygen -t ed25519 -f "$GUEST_SSH_KEY" -q -N ""
fi
update_host_key_registry "$GUEST" "$GUEST_SSH_KEY.pub"

# --- sops-nix integration: derive age key ---
GUEST_AGE_KEY=$(ssh-to-age <"$GUEST_SSH_KEY.pub")
GUEST_ANCHOR="&sv_${GUEST}"
GUEST_ANCHOR_ESCAPED="${GUEST_ANCHOR//&/\\&}"

if grep -q "$GUEST_ANCHOR" "$SOPS_FILE"; then
  EXISTING_GUEST_KEY=$(grep "$GUEST_ANCHOR" "$SOPS_FILE" | sed 's/.*'"$GUEST_ANCHOR"' //')
  if [[ $EXISTING_GUEST_KEY == "$GUEST_AGE_KEY" ]]; then
    echo "  .sops.yaml key already correct"
  else
    echo "  Updating $GUEST_ANCHOR in .sops.yaml..."
    sed -i "s|$GUEST_ANCHOR .*|$GUEST_ANCHOR_ESCAPED $GUEST_AGE_KEY|" "$SOPS_FILE"
  fi
else
  echo ""
  echo "WARNING: No $GUEST_ANCHOR anchor found in .sops.yaml."
  echo "You must manually add the following line to .sops.yaml keys section:"
  echo "  - $GUEST_ANCHOR $GUEST_AGE_KEY"
  echo "and add *sv_$GUEST to the appropriate creation_rules."
  echo ""
fi

# --- Re-encrypt guest secrets ---
if [[ -d $GUEST_SECRET_DIR ]]; then
  GUEST_SECRET_FILES=$(find "$GUEST_SECRET_DIR" -name '*.yaml' 2>/dev/null || true)
  if [[ -n $GUEST_SECRET_FILES ]]; then
    echo "Re-encrypting secrets..."
    echo "$GUEST_SECRET_FILES" | while read -r f; do
      echo "  sops updatekeys: $f"
      sops updatekeys --yes "$f"
    done
  fi
fi

# --- SSH host certificate signing ---
CERTS_DIR="$REPO_ROOT/lib/common/data/host-certs"

if [[ -f "$CERTS_DIR/$GUEST-cert.pub" ]]; then
  echo "SSH host certificate already exists, skipping signing."
  echo "  To re-sign: nix run .#ssh-host-cert-sign -- --sign $GUEST"
else
  SSH_CA_KEY="$KEYFILE_DIR/ssh_host_ca_key"
  if passage show "pki/ssh_host_ca_key" > "$SSH_CA_KEY" 2>/dev/null; then
    chmod 600 "$SSH_CA_KEY"
    echo "Signing SSH host certificate..."
    ALL_HOST_DOMAINS=$(nix eval "$REPO_ROOT#lib.common.data.network.allHostDomains" --json)
    principals=$(echo "$ALL_HOST_DOMAINS" | jq -r --arg h "$GUEST" '.[$h] // [] | join(",")')
    if [[ -n $principals ]]; then
      tmpdir=$(mktemp -d)
      cp "$GUEST_SSH_KEY.pub" "$tmpdir/$GUEST.pub"
      if ssh-keygen -s "$SSH_CA_KEY" -I "$GUEST" -h -n "$principals" -V "+731d" -z "$(date +%s)" "$tmpdir/$GUEST.pub" 2>/dev/null; then
        mkdir -p "$CERTS_DIR"
        mv "$tmpdir/$GUEST-cert.pub" "$CERTS_DIR/$GUEST-cert.pub"
        echo "  Signed host certificate: $GUEST"
      else
        echo "  ssh-keygen signing failed"
      fi
      rm -rf "$tmpdir"
    else
      echo "  $GUEST: not in network registry, skipping certificate"
    fi
  else
    echo "SSH host CA key not found in passage (pki/ssh_host_ca_key) — skipping certificate signing."
    echo "  To sign manually: nix run .#ssh-host-cert-sign -- --sign $GUEST"
  fi
fi

# --- Fleet enrollment key generation/reuse ---
GUEST_ENROLLMENT_KEY="$KEYFILE_DIR/${GUEST}-fleet_enrollment_key"
GUEST_ENROLLMENT_PUB="$KEYFILE_DIR/${GUEST}-fleet_enrollment_key.pub"

if passage show "hosts/$GUEST/fleet_enrollment_key" > "$GUEST_ENROLLMENT_KEY" 2>/dev/null; then
  chmod 600 "$GUEST_ENROLLMENT_KEY"
  openssl pkey -in "$GUEST_ENROLLMENT_KEY" -pubout -out "$GUEST_ENROLLMENT_PUB" 2>/dev/null
  echo "Using existing fleet enrollment key from passage:hosts/$GUEST/fleet_enrollment_key"
else
  echo "Generating new fleet enrollment key..."
  openssl genpkey -algorithm ED25519 -out "$GUEST_ENROLLMENT_KEY"
  openssl pkey -in "$GUEST_ENROLLMENT_KEY" -pubout -out "$GUEST_ENROLLMENT_PUB"
  chmod 600 "$GUEST_ENROLLMENT_KEY"
fi

# Register enrollment pubkey in keys.json
ENROLLMENT_PUB_PEM=$(cat "$GUEST_ENROLLMENT_PUB")
jq --arg name "$GUEST" --arg key "$ENROLLMENT_PUB_PEM" \
  '.fleetEnrollmentKeys[$name] = $key' "$REPO_ROOT/lib/common/data/keys.json" \
  >"$REPO_ROOT/lib/common/data/keys.json.tmp" &&
  mv "$REPO_ROOT/lib/common/data/keys.json.tmp" "$REPO_ROOT/lib/common/data/keys.json"
echo "  Updated keys.json: fleetEnrollmentKeys.$GUEST"

# --- Fleet enrollment certificate signing ---
X5C_CERTS_DIR="$REPO_ROOT/lib/common/data/fleet-x5c-certs"
X5C_CA_CRT="$REPO_ROOT/lib/common/data/pki/fleet_x5c_ca.crt"

if [[ -f "$X5C_CERTS_DIR/$GUEST.crt" ]]; then
  echo "Fleet enrollment certificate already exists, skipping signing."
  echo "  To re-sign: nix run .#fleet-x5c-cert-sign -- --sign $GUEST"
else
  X5C_CA_KEY="$KEYFILE_DIR/fleet_x5c_ca_key"
  if [[ -f $X5C_CA_CRT ]] && passage show "pki/fleet_x5c_ca_key" > "$X5C_CA_KEY" 2>/dev/null; then
    chmod 600 "$X5C_CA_KEY"
    echo "Signing fleet enrollment certificate..."
    if nix run "$REPO_ROOT#fleet-x5c-cert-sign" -- --sign "$GUEST" --ca-key "$X5C_CA_KEY" 2>/dev/null; then
      echo "  Signed enrollment certificate: $GUEST"
    else
      echo "  fleet-x5c-cert-sign failed — check CA key/cert"
    fi
  else
    echo "Fleet X5C CA not yet available — skipping enrollment cert signing."
    echo "  After generating the CA, run: nix run .#fleet-x5c-cert-sign -- --sign $GUEST"
  fi
fi

# --- Store new keys in passage ---
if ! passage show "hosts/$GUEST/ssh_host_ed25519_key" >/dev/null 2>&1; then
  passage insert -m -f "hosts/$GUEST/ssh_host_ed25519_key" < "$GUEST_SSH_KEY"
  echo "Stored SSH key in passage:hosts/$GUEST/ssh_host_ed25519_key"
fi
if ! passage show "hosts/$GUEST/fleet_enrollment_key" >/dev/null 2>&1; then
  passage insert -m -f "hosts/$GUEST/fleet_enrollment_key" < "$GUEST_ENROLLMENT_KEY"
  echo "Stored enrollment key in passage:hosts/$GUEST/fleet_enrollment_key"
fi

# --- Place files ---
place_guest_keys() {
  local dest_dir="$1"

  # SSH host key
  mkdir -p "$dest_dir/persist/guests/${GUEST}/static/etc/ssh"
  cp "$GUEST_SSH_KEY" "$dest_dir/persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key"
  cp "$GUEST_SSH_KEY.pub" "$dest_dir/persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key.pub"
  chmod 600 "$dest_dir/persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key"
  chmod 644 "$dest_dir/persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key.pub"

  if [[ $GUEST_TYPE == "microvm" ]]; then
    mkdir -p "$dest_dir/persist/guests/${GUEST}/images"

    # Fleet enrollment key — placed in static share so service copies it on first boot
    mkdir -p "$dest_dir/persist/guests/${GUEST}/static/fleet-tls"
    cp "$GUEST_ENROLLMENT_KEY" "$dest_dir/persist/guests/${GUEST}/static/fleet-tls/enrollment.key"
    cp "$GUEST_ENROLLMENT_PUB" "$dest_dir/persist/guests/${GUEST}/static/fleet-tls/enrollment.pub"
    chmod 600 "$dest_dir/persist/guests/${GUEST}/static/fleet-tls/enrollment.key"
    chmod 644 "$dest_dir/persist/guests/${GUEST}/static/fleet-tls/enrollment.pub"
  fi
}

if [[ -n $OUTPUT_DIR ]]; then
  echo "Placing files in $OUTPUT_DIR..."
  place_guest_keys "$OUTPUT_DIR"

elif [[ -n $TARGET ]]; then
  echo "Deploying files to $TARGET..."

  DEPLOY_DIR=$(mktemp -d)
  place_guest_keys "$DEPLOY_DIR"

  # shellcheck disable=SC2029
  ssh "$TARGET" "mkdir -p /persist/guests/${GUEST}/static/etc/ssh"
  scp "$DEPLOY_DIR/persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key" \
    "$TARGET:/persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key"
  scp "$DEPLOY_DIR/persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key.pub" \
    "$TARGET:/persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key.pub"
  # shellcheck disable=SC2029
  ssh "$TARGET" "chmod 600 /persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key"
  # shellcheck disable=SC2029
  ssh "$TARGET" "chmod 644 /persist/guests/${GUEST}/static/etc/ssh/ssh_host_ed25519_key.pub"

  if [[ $GUEST_TYPE == "microvm" ]]; then
    NIXOS_CFG="$REPO_ROOT#nixosConfigurations.$PARENT.config"
    MICROVM_UID=$(nix eval "$NIXOS_CFG.common.microvm.uid" 2>/dev/null) || MICROVM_UID=""
    KVM_GID=302
    if [[ -z $MICROVM_UID ]]; then
      echo "WARNING: Could not determine microvm UID, using default 300."
      MICROVM_UID=300
    fi
    # shellcheck disable=SC2029
    ssh "$TARGET" "mkdir -p /persist/guests/${GUEST}/images && chown ${MICROVM_UID}:${KVM_GID} /persist/guests/${GUEST}/images"

    # shellcheck disable=SC2029
    ssh "$TARGET" "mkdir -p /persist/guests/${GUEST}/static/fleet-tls"
    scp "$DEPLOY_DIR/persist/guests/${GUEST}/static/fleet-tls/enrollment.key" \
      "$TARGET:/persist/guests/${GUEST}/static/fleet-tls/enrollment.key"
    scp "$DEPLOY_DIR/persist/guests/${GUEST}/static/fleet-tls/enrollment.pub" \
      "$TARGET:/persist/guests/${GUEST}/static/fleet-tls/enrollment.pub"
    # shellcheck disable=SC2029
    ssh "$TARGET" "chmod 600 /persist/guests/${GUEST}/static/fleet-tls/enrollment.key"
    # shellcheck disable=SC2029
    ssh "$TARGET" "chmod 644 /persist/guests/${GUEST}/static/fleet-tls/enrollment.pub"
  fi

  # shellcheck disable=SC2029
  ssh "$TARGET" "chown -R root:root /persist/guests/${GUEST}/static"

  rm -rf "$DEPLOY_DIR"
  echo "Files deployed to $TARGET:/persist/guests/${GUEST}/"
else
  echo ""
  echo "Keys generated and sops updated. No files placed (use --output-dir or --target to place files)."
fi

echo ""
echo "Done. Guest '$GUEST' setup complete on parent '$PARENT'."
