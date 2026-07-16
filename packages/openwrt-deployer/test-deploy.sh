#!/usr/bin/env bash
set -euo pipefail
DEPLOY=${DEPLOY:-./deploy.sh}
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
BIN=$ROOT/bin STATE=$ROOT/state
mkdir "$BIN" "$STATE"
printf image >"$ROOT/image.bin"
printf host-key >"$ROOT/known_hosts"
SHA=$(sha256sum "$ROOT/image.bin" | cut -d' ' -f1)
cat >"$BIN/scp" <<'EOF'
#!/usr/bin/env bash
exit "${MOCK_SCP_RC:-0}"
EOF
cat >"$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
args="$*"
case "$args" in
  *"sysupgrade -T"*) exit "${MOCK_VALIDATE_RC:-0}" ;;
  *"mmell-dropbear-host-keys.tar.gz"*"tar -C"*) exit "${MOCK_HOST_ARCHIVE_RC:-0}" ;;
  *"sha256sum /tmp/sysupgrade.bin"*) echo "${MOCK_REMOTE_SHA:-$MOCK_SHA}"; exit "${MOCK_REMOTE_SHA_RC:-0}" ;;
  *"__OPENWRT_SYSUPGRADE_START__"*)
    [ "${MOCK_START_MARKER:-1}" = 1 ] && echo __OPENWRT_SYSUPGRADE_START__
    [ "${MOCK_COMMENCED:-0}" = 1 ] && echo 'Commencing upgrade. Closing all shell sessions.'
    exit "${MOCK_UPGRADE_RC:-255}" ;;
  *"cat /proc/sys/kernel/hostname"*) echo "${MOCK_HOSTNAME:-bobcat}"; exit "${MOCK_HOSTNAME_RC:-0}" ;;
  *"cat /etc/mmell-build-id"*) echo "${MOCK_BUILD_ID:-build-1}"; exit "${MOCK_BUILD_ID_RC:-0}" ;;
  *"health-command"*) exit "${MOCK_HEALTH_RC:-0}" ;;
  *"cat /proc/sys/kernel/random/boot_id"*)
    file="$MOCK_STATE/boot-polls"; count=0
    [ ! -f "$file" ] || count=$(cat "$file")
    count=$((count + 1)); echo "$count" >"$file"
    case "$count" in
      1|2) echo old-boot ;;
      3) exit 255 ;;
      *) echo "${MOCK_NEW_BOOT_ID:-new-boot}" ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN"/*
for mock in "$BIN"/*; do
  sed -i "1c #!$BASH" "$mock"
done
run_ok() {
  rm -f "$STATE/boot-polls"
  PATH="$BIN:$PATH" MOCK_STATE="$STATE" MOCK_SHA="$SHA" "$DEPLOY" 192.0.2.1 "$ROOT/image.bin" \
    --ci --known-hosts "$ROOT/known_hosts" --expected-sha256 "$SHA" \
    --expected-hostname bobcat --expected-build-id build-1 --verify-command health-command \
    --poll-interval 0 --reboot-timeout 2 --lock-dir "$ROOT/locks" --json
}
output=$(run_ok)
grep -q '"status":"success"' <<<"$output"
grep -q "\"sha256\":\"$SHA\"" <<<"$output"
set +e
error_output=$(PATH="$BIN:$PATH" MOCK_STATE="$STATE" "$DEPLOY" target "$ROOT/image.bin" --ci --json 2>/dev/null)
error_rc=$?
set -e
[ "$error_rc" -eq 2 ]
grep -q '"status":"error","code":2' <<<"$error_output"
expect_rc() {
  expected=$1
  shift
  rm -f "$STATE/boot-polls"
  set +e
  PATH="$BIN:$PATH" MOCK_STATE="$STATE" MOCK_SHA="$SHA" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] || {
    echo "expected rc $expected, got $rc" >&2
    exit 1
  }
}
expect_rc 2 "$DEPLOY" target "$ROOT/image.bin" --ci
expect_rc 2 "$DEPLOY" target "$ROOT/image.bin" --force --expected-sha256 deadbeef
expect_rc 3 "$DEPLOY" target "$ROOT/image.bin" --force --expected-sha256 "$(printf '0%.0s' {1..64})"
expect_rc 5 env MOCK_SCP_RC=1 "$DEPLOY" target "$ROOT/image.bin" --force --poll-interval 0 --lock-dir "$ROOT/locks"
expect_rc 5 env MOCK_REMOTE_SHA="$(printf '0%.0s' {1..64})" "$DEPLOY" target "$ROOT/image.bin" --force --poll-interval 0 --lock-dir "$ROOT/locks"
expect_rc 5 env MOCK_REMOTE_SHA_RC=1 "$DEPLOY" target "$ROOT/image.bin" --force --poll-interval 0 --lock-dir "$ROOT/locks"
expect_rc 5 env MOCK_VALIDATE_RC=1 "$DEPLOY" target "$ROOT/image.bin" --force --poll-interval 0 --lock-dir "$ROOT/locks"
expect_rc 5 env MOCK_HOST_ARCHIVE_RC=1 "$DEPLOY" target "$ROOT/image.bin" --force --poll-interval 0 --lock-dir "$ROOT/locks"
expect_rc 5 env MOCK_START_MARKER=0 "$DEPLOY" target "$ROOT/image.bin" --force --poll-interval 0 --lock-dir "$ROOT/locks"
expect_rc 5 env MOCK_UPGRADE_RC=42 "$DEPLOY" target "$ROOT/image.bin" --force --poll-interval 0 --lock-dir "$ROOT/locks"
MOCK_COMMENCED=1 MOCK_UPGRADE_RC=246 run_ok >/dev/null
expect_rc 8 env MOCK_HOSTNAME=wrong "$DEPLOY" target "$ROOT/image.bin" --force --expected-hostname bobcat --poll-interval 0 --reboot-timeout 2 --lock-dir "$ROOT/locks"
expect_rc 8 env MOCK_HOSTNAME_RC=1 "$DEPLOY" target "$ROOT/image.bin" --force --expected-hostname bobcat --poll-interval 0 --reboot-timeout 2 --lock-dir "$ROOT/locks"
expect_rc 8 env MOCK_BUILD_ID=wrong "$DEPLOY" target "$ROOT/image.bin" --force --expected-build-id build-1 --poll-interval 0 --reboot-timeout 2 --lock-dir "$ROOT/locks"
expect_rc 8 env MOCK_BUILD_ID_RC=1 "$DEPLOY" target "$ROOT/image.bin" --force --expected-build-id build-1 --poll-interval 0 --reboot-timeout 2 --lock-dir "$ROOT/locks"
expect_rc 9 env MOCK_HEALTH_RC=1 "$DEPLOY" target "$ROOT/image.bin" --force --verify-command health-command --poll-interval 0 --reboot-timeout 2 --lock-dir "$ROOT/locks"
expect_rc 8 env MOCK_NEW_BOOT_ID=old-boot "$DEPLOY" target "$ROOT/image.bin" --force --poll-interval 0 --reboot-timeout 2 --lock-dir "$ROOT/locks"
mkdir -p "$ROOT/held-locks/$(printf target | sha256sum | cut -c1-32)"
expect_rc 4 "$DEPLOY" target "$ROOT/image.bin" --force --lock-dir "$ROOT/held-locks"
echo "openwrt-deployer tests passed"
