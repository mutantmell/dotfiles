#!/usr/bin/env bash
set -euo pipefail

# Issue or renew fleet TLS client certificates for monitored hosts.
# Generates a cert with CN=<hostname> and SCPs it to /var/lib/fleet-tls/ on the host.
# Requires step CLI configured for the internal CA (https://basel.internal).
#
# Usage:
#   ./scripts/issue-fleet-certs.sh [options] [<host> ...]
#
# Options:
#   --provisioner-password-file <file>   Path to step-ca provisioner password file
#                                        (avoids interactive prompts; overrides
#                                        STEP_PROVISIONER_PASSWORD_FILE env var)
#
# Examples:
#   ./scripts/issue-fleet-certs.sh                                       # all hosts, interactive
#   ./scripts/issue-fleet-certs.sh --provisioner-password-file ~/.step/provisioner-password
#   STEP_PROVISIONER_PASSWORD_FILE=~/.step/pw ./scripts/issue-fleet-certs.sh tharbad creil

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for cmd in step ssh scp nix jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd"
    exit 1
  fi
done

PROVISIONER_PASSWORD_FILE="${STEP_PROVISIONER_PASSWORD_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --provisioner-password-file)
    PROVISIONER_PASSWORD_FILE="$2"
    shift 2
    ;;
  --*)
    echo "Unknown option: $1"
    exit 1
    ;;
  *)
    break
    ;;
  esac
done

FLEET_HOSTS_JSON=$(nix eval "$REPO_ROOT#lib.common.data.network.monitoredHosts" --json 2>/dev/null)
ALL_FLEET_HOSTS=$(echo "$FLEET_HOSTS_JSON" | jq -r '.[]')

if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  mapfile -t TARGETS <<<"$ALL_FLEET_HOSTS"
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CA_URL="https://basel.internal"
NOT_AFTER="8760h" # 1 year

STEP_EXTRA_ARGS=()
if [[ -n $PROVISIONER_PASSWORD_FILE ]]; then
  STEP_EXTRA_ARGS+=("--provisioner-password-file" "$PROVISIONER_PASSWORD_FILE")
fi

echo "Issuing fleet TLS client certificates (CA: $CA_URL)"
[[ -n $PROVISIONER_PASSWORD_FILE ]] && echo "Using provisioner password file: $PROVISIONER_PASSWORD_FILE"
echo ""

FAILED=()

for HOST in "${TARGETS[@]}"; do
  echo "--- $HOST ---"

  CERT="$TMPDIR/${HOST}-client.crt"
  KEY="$TMPDIR/${HOST}-client.key"

  if step ca certificate "$HOST" "$CERT" "$KEY" \
    --ca-url "$CA_URL" \
    --san "$HOST" --san "${HOST}.internal" \
    --not-after "$NOT_AFTER" \
    --force \
    "${STEP_EXTRA_ARGS[@]}"; then

    echo "  Deploying to ${HOST}.internal..."
    ssh "root@${HOST}.internal" "mkdir -p /var/lib/fleet-tls && chgrp fleet-tls /var/lib/fleet-tls 2>/dev/null || true"
    scp "$CERT" "root@${HOST}.internal:/var/lib/fleet-tls/client.crt"
    scp "$KEY" "root@${HOST}.internal:/var/lib/fleet-tls/client.key"
    ssh "root@${HOST}.internal" \
      "chmod 644 /var/lib/fleet-tls/client.crt && chmod 640 /var/lib/fleet-tls/client.key && chgrp fleet-tls /var/lib/fleet-tls/client.key"
    echo "  Done."
  else
    echo "  FAILED: step ca certificate returned non-zero for $HOST"
    FAILED+=("$HOST")
  fi

  rm -f "$CERT" "$KEY"
  echo ""
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Failed hosts: ${FAILED[*]}"
  exit 1
fi

echo "Fleet cert issuance complete."
