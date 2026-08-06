#!/usr/bin/env bash
set -euo pipefail

ROOT=$(mktemp -d -t openwrt-deployer-vm-XXXXXX)
QEMU_PID=''
cleanup() {
  if [[ -n $QEMU_PID ]]; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

: "${OPENWRT_BUILDER:?OPENWRT_BUILDER is required}"
: "${OPENWRT_DEPLOYER:?OPENWRT_DEPLOYER is required}"
: "${OPENWRT_VM_FIXTURES:?OPENWRT_VM_FIXTURES is required}"
: "${OPENWRT_DEPLOYER_VM_CONFIG_A:?OPENWRT_DEPLOYER_VM_CONFIG_A is required}"
: "${OPENWRT_DEPLOYER_VM_CONFIG_B:?OPENWRT_DEPLOYER_VM_CONFIG_B is required}"

PORT=$((20000 + $$ % 10000))
HOST=127.0.0.1
CLIENT_KEY="$ROOT/client-key"
KNOWN_HOSTS="$ROOT/known_hosts"
cp "$OPENWRT_VM_FIXTURES/vm-client-ed25519" "$CLIENT_KEY"
chmod 0600 "$CLIENT_KEY"
printf '[%s]:%s %s\n' "$HOST" "$PORT" \
  "$(cut -d' ' -f1,2 "$OPENWRT_VM_FIXTURES/vm-host-ed25519.pub")" >"$KNOWN_HOSTS"

make_manifest() {
  local name=$1
  local config_dir=$2
  local dir="$ROOT/$name"
  mkdir -p "$dir"
  base64 -d "$OPENWRT_VM_FIXTURES/vm-host-ed25519.b64" >"$dir/host-key"
  chmod 0600 "$dir/host-key"
  # Consume the complete Nix-generated manifest and UCI defaults. The only
  # runtime addition is a test-only SSH host key, which keeps host trust
  # deterministic. Keeping the generated defaults intact makes this test cover
  # production cleanup of intrinsic networking.
  jq --arg host_key "$dir/host-key" \
    '.extraFiles["/etc/dropbear/dropbear_ed25519_host_key"] = $host_key' \
    "$config_dir/build.json" >"$dir/build.json"
  "$OPENWRT_BUILDER" --config-file "$dir/build.json" --output-dir "$dir/out" --no-secrets
}

BUILD_A=$(jq -er '.buildId' "$OPENWRT_DEPLOYER_VM_CONFIG_A/build.json")
BUILD_B=$(jq -er '.buildId' "$OPENWRT_DEPLOYER_VM_CONFIG_B/build.json")
make_manifest A "$OPENWRT_DEPLOYER_VM_CONFIG_A"
make_manifest B "$OPENWRT_DEPLOYER_VM_CONFIG_B"

IMAGE_A_GZ=$(find "$ROOT/A/out" -name '*ext4-combined.img.gz' -print -quit)
IMAGE_B=$(find "$ROOT/B/out" -name '*ext4-combined.img.gz' -print -quit)
[[ -n $IMAGE_A_GZ && -n $IMAGE_B ]]
# OpenWrt pads the compressed disk artifact; gzip reports the valid trailing
# bytes as rc 2 after successfully producing the complete raw image.
set +e
gzip -dc "$IMAGE_A_GZ" >"$ROOT/openwrt.img"
gzip_rc=$?
set -e
[[ $gzip_rc -eq 0 || $gzip_rc -eq 2 ]]

qemu-system-x86_64 \
  -machine pc,accel=kvm:tcg -m 256 -nographic \
  -drive "file=$ROOT/openwrt.img,format=raw,if=ide" \
  -netdev "user,id=net0,hostfwd=tcp::$PORT-:22" \
  -device e1000,netdev=net0 >"$ROOT/qemu.log" 2>&1 &
QEMU_PID=$!

SSH=(ssh -p "$PORT" -i "$CLIENT_KEY" -o IdentitiesOnly=yes -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=2 "root@$HOST")
assert_uci_absent() {
  local section=$1
  if "${SSH[@]}" uci -q get "$section"; then
    echo "unexpected intrinsic UCI section survived: $section" >&2
    exit 1
  fi
}
deadline=$((SECONDS + 180))
until "${SSH[@]}" true >/dev/null 2>&1; do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    cat "$ROOT/qemu.log" >&2
    echo 'QEMU exited before SSH became available' >&2
    exit 1
  fi
  ((SECONDS < deadline)) || {
    cat "$ROOT/qemu.log" >&2
    exit 1
  }
  sleep 2
done

OLD_BOOT_ID=$("${SSH[@]}" cat /proc/sys/kernel/random/boot_id)
[[ -n $OLD_BOOT_ID ]]
[[ $("${SSH[@]}" cat /etc/mmell-build-id) == "$BUILD_A" ]]
[[ $("${SSH[@]}" uci -q get 'system.@system[0].description') == deployment-A ]]
[[ $("${SSH[@]}" uci -q get network.uplink.device) == eth0 ]]
[[ $("${SSH[@]}" uci -q get network.uplink.proto) == dhcp ]]
assert_uci_absent network.lan
assert_uci_absent network.wan
assert_uci_absent 'network.@device[0]'
"${SSH[@]}" ip -4 address show dev eth0 | grep -q 'inet '

SHA=$(sha256sum "$IMAGE_B" | cut -d' ' -f1)
RESULT=$("$OPENWRT_DEPLOYER" "$HOST" "$IMAGE_B" \
  --ci --ssh-key "$CLIENT_KEY" --known-hosts "$KNOWN_HOSTS" \
  --ssh-port "$PORT" \
  --expected-sha256 "$SHA" --expected-hostname openwrt-deployer-vm \
  --expected-build-id "$BUILD_B" \
  --verify-command "test \"\$(uci -q get 'system.@system[0].description')\" = deployment-B" \
  --verify-command "! grep -q deployment-A /etc/config/system" \
  --verify-command 'ubus call system board >/dev/null' \
  --reboot-timeout 180 --poll-interval 2 --lock-dir "$ROOT/locks" --json)

NEW_BOOT_ID=$("${SSH[@]}" cat /proc/sys/kernel/random/boot_id)
[[ $NEW_BOOT_ID != "$OLD_BOOT_ID" ]]
[[ $("${SSH[@]}" cat /etc/mmell-build-id) == "$BUILD_B" ]]
[[ $("${SSH[@]}" uci -q get network.uplink.device) == eth0 ]]
[[ $("${SSH[@]}" uci -q get network.uplink.proto) == dhcp ]]
assert_uci_absent network.lan
assert_uci_absent network.wan
assert_uci_absent 'network.@device[0]'
"${SSH[@]}" ip -4 address show dev eth0 | grep -q 'inet '
jq -e --arg sha "$SHA" --arg build "$BUILD_B" \
  '.status == "success" and .sha256 == $sha and .build_id == $build' <<<"$RESULT" >/dev/null
echo 'OpenWrt deployer VM integration test passed.'
