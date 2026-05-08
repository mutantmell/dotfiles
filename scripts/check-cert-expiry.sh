#!/usr/bin/env bash
set -euo pipefail

# Check certificate expiry for SSH host certs and fleet X5C enrollment certs.
#
# Exit codes:
#   0 — all certs valid and all expected certs present
#   1 — any cert expired, within fail threshold, or missing
#
# Thresholds:
#   SSH host certs:          warn < 60d, fail < 14d
#   X5C enrollment certs:    warn < 450d (silent-expiry trap: enrollment cert must
#                            outlast the issued client cert by >= 365d)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_CERTS_DIR="$REPO_ROOT/lib/common/data/host-certs"
X5C_CERTS_DIR="$REPO_ROOT/lib/common/data/fleet-x5c-certs"

WARN=0
FAIL=0

now_sec=$(date +%s)
warn_ssh_days=60
fail_ssh_days=14
warn_x5c_days=450

days_until() {
  local end_sec="$1"
  echo $(((end_sec - now_sec) / 86400))
}

# Parse SSH cert expiry from "Valid: from ... to YYYY-MM-DDTHH:MM:SS" line
ssh_cert_end_epoch() {
  local cert="$1"
  local valid_line
  valid_line=$(ssh-keygen -L -f "$cert" 2>/dev/null | grep "Valid:" || true)
  if [ -z "$valid_line" ]; then
    echo "0"
    return
  fi
  local end_str="${valid_line##*to }"
  date -d "$end_str" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "$end_str" +%s 2>/dev/null || echo "0"
}

# Parse X509 cert expiry from openssl
x509_cert_end_epoch() {
  local cert="$1"
  local end_str
  end_str=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | sed 's/notAfter=//' || true)
  if [ -z "$end_str" ]; then
    echo "0"
    return
  fi
  date -d "$end_str" +%s 2>/dev/null || date -jf "%b %e %H:%M:%S %Y %Z" "$end_str" +%s 2>/dev/null || echo "0"
}

# Fetch the network registry's monitored host list
ALL_DOMAINS=$(nix eval "$REPO_ROOT#lib.common.data.network.allHostDomains" --json 2>/dev/null)
all_hosts=$(echo "$ALL_DOMAINS" | jq -r 'keys[]')

# Only check SSH host certs for hosts with a known host key (i.e., running sshd).
# Hosts without a hostKeys entry (OpenWrt devices, switches, IoT, not-yet-deployed
# hardware) are not expected to have SSH host certs.
KEYS_JSON="$REPO_ROOT/lib/common/data/keys.json"

echo "=== SSH host certificate expiry ==="
for host in $all_hosts; do
  has_host_key=$(jq -r --arg h "$host" '.hostKeys[$h] // empty' "$KEYS_JSON" 2>/dev/null || true)
  if [ -z "$has_host_key" ]; then
    continue # No hostKeys entry — cert not expected for this host
  fi
  cert="$HOST_CERTS_DIR/$host-cert.pub"
  if [ ! -f "$cert" ]; then
    echo "  MISSING  $host: no SSH host cert at host-certs/$host-cert.pub"
    FAIL=$((FAIL + 1))
    continue
  fi
  end_sec=$(ssh_cert_end_epoch "$cert")
  days=$(days_until "$end_sec")
  if [ "$days" -lt "$fail_ssh_days" ]; then
    echo "  FAIL     $host: SSH host cert expires in ${days}d (threshold: ${fail_ssh_days}d)"
    FAIL=$((FAIL + 1))
  elif [ "$days" -lt "$warn_ssh_days" ]; then
    echo "  WARN     $host: SSH host cert expires in ${days}d (threshold: ${warn_ssh_days}d)"
    WARN=$((WARN + 1))
  else
    echo "  ok       $host: SSH host cert expires in ${days}d"
  fi
done

# Orphan check: certs in host-certs/ with no matching host
if [ -d "$HOST_CERTS_DIR" ]; then
  for cert in "$HOST_CERTS_DIR"/*-cert.pub; do
    [ -f "$cert" ] || continue
    base=$(basename "$cert" -cert.pub)
    in_registry=$(echo "$ALL_DOMAINS" | jq -r --arg h "$base" 'has($h)')
    if [ "$in_registry" != "true" ]; then
      echo "  ORPHAN   $base: host-certs/$base-cert.pub has no matching network registry entry"
      WARN=$((WARN + 1))
    fi
  done
fi

echo ""
echo "=== Fleet X5C enrollment certificate expiry ==="
if [ ! -d "$X5C_CERTS_DIR" ] || ! compgen -G "$X5C_CERTS_DIR/*.crt" >/dev/null; then
  echo "  (no X5C enrollment certs found — skipping X5C checks)"
else
  for host in $all_hosts; do
    cert="$X5C_CERTS_DIR/$host.crt"
    if [ ! -f "$cert" ]; then
      # Only fail if there's a fleetEnrollmentKeys entry for this host
      has_key=$(jq -r --arg h "$host" '.fleetEnrollmentKeys[$h] // empty' \
        "$REPO_ROOT/lib/common/data/keys.json" 2>/dev/null || true)
      if [ -n "$has_key" ]; then
        echo "  MISSING  $host: enrollment key registered but no cert at fleet-x5c-certs/$host.crt"
        FAIL=$((FAIL + 1))
      fi
      continue
    fi
    end_sec=$(x509_cert_end_epoch "$cert")
    days=$(days_until "$end_sec")
    if [ "$days" -lt 0 ]; then
      echo "  FAIL     $host: X5C enrollment cert EXPIRED ${days#-}d ago"
      FAIL=$((FAIL + 1))
    elif [ "$days" -lt "$warn_x5c_days" ]; then
      echo "  WARN     $host: X5C enrollment cert expires in ${days}d (threshold: ${warn_x5c_days}d — rotate before issuance window closes)"
      WARN=$((WARN + 1))
    else
      echo "  ok       $host: X5C enrollment cert expires in ${days}d"
    fi
  done

  # Orphan check: certs in fleet-x5c-certs/ with no matching host
  for cert in "$X5C_CERTS_DIR"/*.crt; do
    [ -f "$cert" ] || continue
    base=$(basename "$cert" .crt)
    in_registry=$(echo "$ALL_DOMAINS" | jq -r --arg h "$base" 'has($h)')
    if [ "$in_registry" != "true" ]; then
      echo "  ORPHAN   $base: fleet-x5c-certs/$base.crt has no matching network registry entry"
      WARN=$((WARN + 1))
    fi
  done
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "cert-expiry: FAIL ($FAIL failures, $WARN warnings)"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "cert-expiry: WARN ($WARN warnings)"
  exit 0
else
  echo "cert-expiry: all certs valid"
fi
