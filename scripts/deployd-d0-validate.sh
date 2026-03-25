#!/usr/bin/env bash
# D0 validation: drive the full deployd stack end-to-end.
#
# Builds a Claude Code sandbox OCI image, pushes it to creil, deploys
# it via deployd-api on roer, verifies the container is directly reachable
# via SSH, then tears it down.
#
# Prerequisites:
#   - Network access to creil.internal, roer.internal, erebonia.internal
#   - skopeo and jq available (nix-shell -p skopeo jq)
#   - Keycloak account in homelab realm with 'deploy' group membership
#     Set DEPLOYD_USER and DEPLOYD_PASS, or you will be prompted.
#   - Forgejo account with write:package access to the deployd org on creil.internal
#     Set FORGEJO_USER and FORGEJO_TOKEN, or you will be prompted.
#
# Usage: ./scripts/deployd-d0-validate.sh [--skip-build] [--skip-push] [--skip-deploy]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REGISTRY="creil.internal"
IMAGE_NAME="deployd/claude-sandbox"
IMAGE_TAG="latest"
CONTAINER_NAME="claude-sandbox"
AUTH_URL="https://auth.mutantmell.net/realms/homelab/protocol/openid-connect/token"
API_URL="https://roer.internal/api/v1"
EREBONIA_HOST="root@erebonia.internal"
CACERT="$REPO_DIR/lib/common/data/pki/root_ca.crt"

SKIP_BUILD=false
SKIP_PUSH=false
SKIP_DEPLOY=false

for arg in "$@"; do
  case "$arg" in
  --skip-build) SKIP_BUILD=true ;;
  --skip-push) SKIP_PUSH=true ;;
  --skip-deploy) SKIP_DEPLOY=true; SKIP_BUILD=true; SKIP_PUSH=true ;;
  *)
    echo "Unknown arg: $arg"
    exit 1
    ;;
  esac
done

log() { echo "==> $*"; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [ "$SKIP_DEPLOY" = false ]; then
  # Step 1: Build OCI image
  if [ "$SKIP_BUILD" = false ]; then
    log "Building claude-sandbox-image..."
  fi
  IMAGE_PATH="$(nix build "$REPO_DIR#claude-sandbox-image" --print-out-paths --no-link)"
  log "Image at: $IMAGE_PATH"

  # Step 2: Push to registry
  if [ "$SKIP_PUSH" = false ]; then
    if [ -z "${FORGEJO_USER:-}" ]; then
      read -rp "Forgejo username: " FORGEJO_USER
    fi
    if [ -z "${FORGEJO_TOKEN:-}" ]; then
      read -rsp "Forgejo token: " FORGEJO_TOKEN
      echo
    fi
    log "Pushing image to $REGISTRY/$IMAGE_NAME:$IMAGE_TAG..."
    skopeo copy \
      --insecure-policy \
      --dest-creds "$FORGEJO_USER:$FORGEJO_TOKEN" \
      "docker-archive:$IMAGE_PATH" \
      "docker://$REGISTRY/$IMAGE_NAME:$IMAGE_TAG" \
      --dest-tls-verify=false
  fi

  # Step 3: Get image digest
  log "Fetching image digest..."
  DIGEST="$(skopeo inspect --insecure-policy "docker://$REGISTRY/$IMAGE_NAME:$IMAGE_TAG" --tls-verify=false | jq -r .Digest)"
  [ -n "$DIGEST" ] || fail "Could not fetch image digest"
  log "Digest: $DIGEST"
  FULL_IMAGE="$REGISTRY/$IMAGE_NAME@$DIGEST"

  # Step 4: Get OAuth2 token
  log "Authenticating with Keycloak (deployd-operator client)..."
  if [ -z "${DEPLOYD_USER:-}" ]; then
    read -rp "Username: " DEPLOYD_USER
  fi
  if [ -z "${DEPLOYD_PASS:-}" ]; then
    read -rsp "Password: " DEPLOYD_PASS
    echo
  fi

  TOKEN_RESPONSE="$(curl -sf --cacert "$CACERT" -X POST "$AUTH_URL" \
    -d "grant_type=password" \
    -d "client_id=deployd-operator" \
    -d "username=$DEPLOYD_USER" \
    -d "password=$DEPLOYD_PASS")" || fail "Token request failed"
  TOKEN="$(echo "$TOKEN_RESPONSE" | jq -r .access_token)"
  [ "$TOKEN" != "null" ] && [ -n "$TOKEN" ] || fail "No access token in response"
  log "Got access token"

  # Step 5a: Tear down any existing container with the same name
  log "Tearing down any existing $CONTAINER_NAME..."
  PRE_TEARDOWN_CODE="$(curl -s --cacert "$CACERT" -o /dev/null -w "%{http_code}" \
    -X DELETE "$API_URL/teardown/$CONTAINER_NAME" \
    -H "Authorization: Bearer $TOKEN")"
  if [ "$PRE_TEARDOWN_CODE" -ge 200 ] && [ "$PRE_TEARDOWN_CODE" -lt 300 ]; then
    log "Existing container torn down"
    sleep 2
  else
    log "No existing container (HTTP $PRE_TEARDOWN_CODE), continuing"
  fi

  # Step 5b: Deploy via deployd-api
  log "Deploying $CONTAINER_NAME via deployd-api..."
  DEPLOY_RESPONSE="$(curl -s --cacert "$CACERT" -w "\n%{http_code}" -X POST "$API_URL/deploy" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$CONTAINER_NAME\",\"image\":\"$FULL_IMAGE\"}")" \
    || fail "Deploy request failed (curl error $?)"
  DEPLOY_HTTP_CODE="$(echo "$DEPLOY_RESPONSE" | tail -1)"
  DEPLOY_BODY="$(echo "$DEPLOY_RESPONSE" | head -n -1)"
  [ "$DEPLOY_HTTP_CODE" -ge 200 ] && [ "$DEPLOY_HTTP_CODE" -lt 300 ] \
    || fail "Deploy request failed (HTTP $DEPLOY_HTTP_CODE): $DEPLOY_BODY"
  echo "Deploy response: $DEPLOY_BODY"
fi

# Step 6: Discover container IP (for L2 connectivity check)
log "Waiting for container to start..."
sleep 3
# shellcheck disable=SC2029 # Intentional client-side expansion
CONTAINER_IP="$(ssh "$EREBONIA_HOST" \
  "podman inspect systemd-$CONTAINER_NAME --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'")" ||
  fail "Could not inspect container on $EREBONIA_HOST"
[ -n "$CONTAINER_IP" ] || fail "Container has no IP"
log "Container IP: $CONTAINER_IP"

# Step 7: Verify connectivity (retry for up to 30s)
log "Pinging container..."
for i in $(seq 1 10); do
  ping -c 1 -W 3 "$CONTAINER_IP" >/dev/null 2>&1 && break
  [ "$i" -eq 10 ] && fail "Container unreachable from local host after 30s"
  sleep 3
done
log "Ping OK"

# Step 8: Verify SSH (retry for up to 30s — sshd may still be starting)
log "Testing SSH to claude@$CONTAINER_IP..."
for i in $(seq 1 10); do
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "claude@$CONTAINER_IP" \
    "echo 'SSH OK'; uname -a" && break
  [ "$i" -eq 10 ] && fail "SSH unreachable after 30s"
  sleep 3
done
log "SSH OK"

# Step 9: Interactive phase
log ""
log "Container is running at $CONTAINER_IP"
log "  SSH: ssh -o StrictHostKeyChecking=no claude@$CONTAINER_IP"
log ""
read -rp "Press Enter to tear down (or Ctrl-C to leave running)... "

# Step 10: Teardown — re-authenticate in case token expired or --skip-deploy was used
log "Tearing down $CONTAINER_NAME..."
if [ -z "${DEPLOYD_USER:-}" ]; then
  read -rp "Username: " DEPLOYD_USER
fi
if [ -z "${DEPLOYD_PASS:-}" ]; then
  read -rsp "Password: " DEPLOYD_PASS
  echo
fi
TOKEN_RESPONSE="$(curl -sf --cacert "$CACERT" -X POST "$AUTH_URL" \
  -d "grant_type=password" \
  -d "client_id=deployd-operator" \
  -d "username=$DEPLOYD_USER" \
  -d "password=$DEPLOYD_PASS")" || fail "Token refresh failed"
TOKEN="$(echo "$TOKEN_RESPONSE" | jq -r .access_token)"

TEARDOWN_RESPONSE="$(curl -s --cacert "$CACERT" -w "\n%{http_code}" -X DELETE "$API_URL/teardown/$CONTAINER_NAME" \
  -H "Authorization: Bearer $TOKEN")" \
  || fail "Teardown request failed (curl error $?)"
TEARDOWN_HTTP_CODE="$(echo "$TEARDOWN_RESPONSE" | tail -1)"
TEARDOWN_BODY="$(echo "$TEARDOWN_RESPONSE" | head -n -1)"
[ "$TEARDOWN_HTTP_CODE" -ge 200 ] && [ "$TEARDOWN_HTTP_CODE" -lt 300 ] \
  || fail "Teardown request failed (HTTP $TEARDOWN_HTTP_CODE): $TEARDOWN_BODY"
echo "Teardown response: $TEARDOWN_BODY"
log "Teardown complete"

log "D0 validation complete!"
