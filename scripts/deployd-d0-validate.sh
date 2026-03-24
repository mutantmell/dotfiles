#!/usr/bin/env bash
# D0 validation: drive the full deployd stack end-to-end.
#
# Builds a Claude Code sandbox OCI image, pushes it to creil, deploys
# it via deployd-api on roer, verifies the container is reachable on
# the DMZ network, then tears it down.
#
# Prerequisites:
#   - Network access to creil.internal, roer.internal, erebonia
#   - skopeo and jq available (nix-shell -p skopeo jq)
#   - Keycloak account in homelab realm with 'deploy' group membership
#
# Usage: ./scripts/deployd-d0-validate.sh [--skip-build] [--skip-push]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REGISTRY="creil.internal"
IMAGE_NAME="deployd/claude-sandbox"
IMAGE_TAG="latest"
CONTAINER_NAME="claude-sandbox"
AUTH_URL="https://auth.mutantmell.net/realms/homelab/protocol/openid-connect/token"
API_URL="https://roer.internal/api/v1"
EREBONIA_HOST="erebonia"

SKIP_BUILD=false
SKIP_PUSH=false

for arg in "$@"; do
  case "$arg" in
  --skip-build) SKIP_BUILD=true ;;
  --skip-push) SKIP_PUSH=true ;;
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

# Step 1: Build OCI image
if [ "$SKIP_BUILD" = false ]; then
  log "Building claude-sandbox-image..."
  nix build "$REPO_DIR#claude-sandbox-image" --print-out-paths --no-link
fi
IMAGE_PATH="$(nix build "$REPO_DIR#claude-sandbox-image" --print-out-paths --no-link)"
log "Image at: $IMAGE_PATH"

# Step 2: Push to registry
if [ "$SKIP_PUSH" = false ]; then
  log "Pushing image to $REGISTRY/$IMAGE_NAME:$IMAGE_TAG..."
  skopeo copy \
    "docker-archive:$IMAGE_PATH" \
    "docker://$REGISTRY/$IMAGE_NAME:$IMAGE_TAG" \
    --dest-tls-verify=false
fi

# Step 3: Get image digest
log "Fetching image digest..."
DIGEST="$(skopeo inspect "docker://$REGISTRY/$IMAGE_NAME:$IMAGE_TAG" --tls-verify=false | jq -r .Digest)"
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

TOKEN_RESPONSE="$(curl -sf -X POST "$AUTH_URL" \
  -d "grant_type=password" \
  -d "client_id=deployd-operator" \
  -d "username=$DEPLOYD_USER" \
  -d "password=$DEPLOYD_PASS")" || fail "Token request failed"
TOKEN="$(echo "$TOKEN_RESPONSE" | jq -r .access_token)"
[ "$TOKEN" != "null" ] && [ -n "$TOKEN" ] || fail "No access token in response"
log "Got access token"

# Step 5: Deploy via deployd-api
log "Deploying $CONTAINER_NAME via deployd-api..."
DEPLOY_RESPONSE="$(curl -sf -X POST "$API_URL/deploy" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$CONTAINER_NAME\",\"image\":\"$FULL_IMAGE\"}")" || fail "Deploy request failed"
echo "Deploy response: $DEPLOY_RESPONSE"

# Step 6: Discover container IP
log "Waiting for container to start..."
sleep 3
# shellcheck disable=SC2029 # Intentional client-side expansion
CONTAINER_IP="$(ssh "$EREBONIA_HOST" \
  "podman inspect $CONTAINER_NAME --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'" 2>/dev/null)" ||
  fail "Could not inspect container on $EREBONIA_HOST"
[ -n "$CONTAINER_IP" ] || fail "Container has no IP"
log "Container IP: $CONTAINER_IP"

# Step 7: Verify connectivity
log "Pinging container..."
if ping -c 3 -W 2 "$CONTAINER_IP" >/dev/null 2>&1; then
  log "Ping OK (direct)"
else
  log "Ping failed (may be expected if not on DMZ network). Trying via erebonia..."
  # shellcheck disable=SC2029 # Intentional client-side expansion
  ssh "$EREBONIA_HOST" "ping -c 3 -W 2 $CONTAINER_IP" || fail "Container unreachable even from erebonia"
  log "Ping OK (via erebonia)"
fi

# Step 8: Verify SSH
log "Waiting for sshd to start..."
sleep 2
log "Testing SSH to claude@$CONTAINER_IP..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "claude@$CONTAINER_IP" "echo 'SSH OK'; uname -a" 2>/dev/null; then
  log "SSH OK (direct)"
else
  log "Direct SSH failed, trying via erebonia as jump host..."
  # shellcheck disable=SC2029 # Intentional client-side expansion
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -J "$EREBONIA_HOST" "claude@$CONTAINER_IP" \
    "echo 'SSH OK'; uname -a" || fail "SSH unreachable"
  log "SSH OK (via erebonia)"
fi

# Step 9: Interactive phase
log ""
log "Container is running at $CONTAINER_IP"
log "  SSH:  ssh -o StrictHostKeyChecking=no claude@$CONTAINER_IP"
log "  Jump: ssh -o StrictHostKeyChecking=no -J $EREBONIA_HOST claude@$CONTAINER_IP"
log ""
read -rp "Press Enter to tear down (or Ctrl-C to leave running)... "

# Step 10: Teardown
log "Tearing down $CONTAINER_NAME..."
# Re-fetch token in case it expired
TOKEN_RESPONSE="$(curl -sf -X POST "$AUTH_URL" \
  -d "grant_type=password" \
  -d "client_id=deployd-operator" \
  -d "username=$DEPLOYD_USER" \
  -d "password=$DEPLOYD_PASS")" || fail "Token refresh failed"
TOKEN="$(echo "$TOKEN_RESPONSE" | jq -r .access_token)"

TEARDOWN_RESPONSE="$(curl -sf -X DELETE "$API_URL/teardown/$CONTAINER_NAME" \
  -H "Authorization: Bearer $TOKEN")" || fail "Teardown request failed"
echo "Teardown response: $TEARDOWN_RESPONSE"
log "Teardown complete"

log "D0 validation complete!"
