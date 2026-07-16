#!/usr/bin/env bash
set -euo pipefail
usage() {
  cat <<'EOF'
Usage: openwrt-deploy <target> <image> [options]
  --force                    Skip manual confirmation
  --ci                       Noninteractive mode (requires trust + digest inputs)
  --ssh-key PATH             SSH private key
  --known-hosts PATH         Caller-managed known_hosts file
  --expected-sha256 HEX      Require the local image SHA-256
  --expected-hostname NAME   Verify hostname after reboot
  --expected-build-id ID     Verify /etc/mmell-build-id after reboot
  --verify-command COMMAND   Additional remote health check (repeatable)
  --reboot-timeout SECONDS   Offline/online timeout (default: 300)
  --poll-interval SECONDS    Poll interval (default: 5)
  --json                     Emit a machine-readable success result
  --lock-dir DIR             Local per-target lock parent
EOF
}
die() {
  message=$1
  code=${2:-1}
  echo "Error: $message" >&2
  if [ -n "${JSON:-}" ]; then
    jq -cn --argjson code "$code" --arg target "${TARGET:-}" --arg message "$message" \
      '{status:"error",code:$code,target:$target,message:$message}'
  fi
  exit "$code"
}
progress() { echo "$*" >&2; }
[ $# -ge 2 ] || {
  usage
  exit 2
}
TARGET=$1 IMAGE=$2
shift 2
FORCE='' CI='' JSON='' SSH_KEY='' KNOWN_HOSTS='' EXPECTED_SHA256=''
EXPECTED_HOSTNAME='' EXPECTED_BUILD_ID='' LOCK_PARENT=''
REBOOT_TIMEOUT=300 POLL_INTERVAL=5
VERIFY_COMMANDS=()
while [ $# -gt 0 ]; do
  case "$1" in
  --force) FORCE=1 ;;
  --ci) CI=1 ;;
  --json) JSON=1 ;;
  --ssh-key | --known-hosts | --expected-sha256 | --expected-hostname | --expected-build-id | --verify-command | --reboot-timeout | --poll-interval | --lock-dir)
    option=$1
    shift
    [ $# -gt 0 ] || die "$option requires a value" 2
    case "$option" in
    --ssh-key) SSH_KEY=$1 ;;
    --known-hosts) KNOWN_HOSTS=$1 ;;
    --expected-sha256) EXPECTED_SHA256=$1 ;;
    --expected-hostname) EXPECTED_HOSTNAME=$1 ;;
    --expected-build-id) EXPECTED_BUILD_ID=$1 ;;
    --verify-command) VERIFY_COMMANDS+=("$1") ;;
    --reboot-timeout) REBOOT_TIMEOUT=$1 ;;
    --poll-interval) POLL_INTERVAL=$1 ;;
    --lock-dir) LOCK_PARENT=$1 ;;
    esac
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown argument: $1" 2 ;;
  esac
  shift
done
[ -f "$IMAGE" ] || die "image file not found: $IMAGE"
[[ $REBOOT_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die "--reboot-timeout must be a positive integer" 2
[[ $POLL_INTERVAL =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--poll-interval must be non-negative" 2
if [ -n "$CI" ]; then
  [ -n "$KNOWN_HOSTS" ] || die "--ci requires --known-hosts" 2
  [ -n "$EXPECTED_SHA256" ] || die "--ci requires --expected-sha256" 2
  FORCE=1
fi
if [ -n "$KNOWN_HOSTS" ]; then
  [ -f "$KNOWN_HOSTS" ] || die "known_hosts file not found: $KNOWN_HOSTS"
fi
ACTUAL_SHA256=$(sha256sum "$IMAGE" | cut -d' ' -f1)
EXPECTED_SHA256=$(printf %s "$EXPECTED_SHA256" | tr A-F a-f)
if [ -n "$EXPECTED_SHA256" ] && [[ ! $EXPECTED_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
  die "--expected-sha256 must be exactly 64 hexadecimal characters" 2
fi
if [ -n "$EXPECTED_SHA256" ] && [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  die "image SHA-256 mismatch (expected $EXPECTED_SHA256, got $ACTUAL_SHA256)" 3
fi
LOCK_PARENT=${LOCK_PARENT:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/openwrt-deployer-locks}
mkdir -p "$LOCK_PARENT"
chmod 700 "$LOCK_PARENT"
LOCK_NAME=$(printf %s "$TARGET" | sha256sum | cut -c1-32)
LOCK="$LOCK_PARENT/$LOCK_NAME"
mkdir "$LOCK" 2>/dev/null || die "another deployment to $TARGET holds $LOCK" 4
LOG=$(mktemp -t openwrt-sysupgrade-XXXXXX.log)
cleanup() {
  rm -f "$LOG"
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
SSH_OPTS=(-o ConnectTimeout=10)
[ -z "$SSH_KEY" ] || SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
if [ -n "$KNOWN_HOSTS" ]; then
  SSH_OPTS+=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null)
fi
[ -z "$CI" ] || SSH_OPTS+=(-o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no)
# Commands passed to this helper are intentional remote shell fragments.
# shellcheck disable=SC2029
remote() { ssh "${SSH_OPTS[@]}" "root@$TARGET" "$@"; }
progress "Image: $IMAGE"
progress "SHA-256: $ACTUAL_SHA256"
progress "Target: $TARGET"
if [ -z "$FORCE" ]; then
  read -r -p "Deploy to $TARGET? This will reboot the device. [y/N] " reply
  [[ $reply =~ ^[Yy]$ ]] || {
    progress Aborted.
    exit 0
  }
fi
progress "Uploading and validating image..."
scp -O "${SSH_OPTS[@]}" "$IMAGE" "root@$TARGET:/tmp/sysupgrade.bin" || die "image upload failed" 5
remote_sha256=$(remote "sha256sum /tmp/sysupgrade.bin | cut -d' ' -f1") || die "could not hash uploaded image" 5
[ "$remote_sha256" = "$ACTUAL_SHA256" ] || die "uploaded image SHA-256 mismatch (local $ACTUAL_SHA256, remote $remote_sha256)" 5
remote "command -v sysupgrade >/dev/null && sysupgrade -T /tmp/sysupgrade.bin" || die "remote image validation failed" 5
progress "Starting sysupgrade..."
set +e
remote "echo __OPENWRT_SYSUPGRADE_START__; exec sysupgrade -v /tmp/sysupgrade.bin" >"$LOG" 2>&1
rc=$?
set -e
cat "$LOG" >&2
case "$rc" in
0) progress "sysupgrade completed before disconnect" ;;
255)
  grep -q __OPENWRT_SYSUPGRADE_START__ "$LOG" || die "SSH disconnected before sysupgrade start was confirmed" 5
  progress "SSH disconnected after sysupgrade started"
  ;;
*) die "sysupgrade failed before reboot (ssh exit $rc)" 5 ;;
esac
deadline=$((SECONDS + REBOOT_TIMEOUT))
progress "Waiting for the device to go offline..."
while remote true >/dev/null 2>&1; do
  [ "$SECONDS" -lt "$deadline" ] || die "device did not go offline within ${REBOOT_TIMEOUT}s" 6
  sleep "$POLL_INTERVAL"
done
deadline=$((SECONDS + REBOOT_TIMEOUT))
progress "Waiting for the device to return..."
until remote true >/dev/null 2>&1; do
  [ "$SECONDS" -lt "$deadline" ] || die "device did not return within ${REBOOT_TIMEOUT}s" 7
  sleep "$POLL_INTERVAL"
done
progress "Verifying returned device..."
if [ -n "$EXPECTED_HOSTNAME" ]; then
  actual=$(remote "cat /proc/sys/kernel/hostname") || die "could not read returned device hostname" 8
  [ "$actual" = "$EXPECTED_HOSTNAME" ] || die "hostname mismatch (expected $EXPECTED_HOSTNAME, got $actual)" 8
fi
if [ -n "$EXPECTED_BUILD_ID" ]; then
  actual=$(remote "cat /etc/mmell-build-id") || die "could not read returned device build ID" 8
  [ "$actual" = "$EXPECTED_BUILD_ID" ] || die "build ID mismatch (expected $EXPECTED_BUILD_ID, got $actual)" 8
fi
for command in "${VERIFY_COMMANDS[@]}"; do
  remote "$command" || die "health check failed: $command" 9
done
if [ -n "$JSON" ]; then
  jq -cn --arg target "$TARGET" --arg image "$IMAGE" --arg sha256 "$ACTUAL_SHA256" \
    --arg build_id "$EXPECTED_BUILD_ID" \
    '{status:"success",target:$target,image:$image,sha256:$sha256,build_id:$build_id}'
else
  echo "Deployment verified successfully."
fi
