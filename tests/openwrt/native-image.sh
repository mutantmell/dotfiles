#!/usr/bin/env bash
set -euo pipefail

: "${OPENWRT_BUILDER:?OPENWRT_BUILDER is required}"
: "${OPENWRT_NATIVE_CONFIG:?OPENWRT_NATIVE_CONFIG is required}"

ROOT=$(mktemp -d -t openwrt-native-image-XXXXXX)
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT INT TERM HUP

fail() {
  echo "native image check failed: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1 pattern=$2 description=$3
  grep -Fq -- "$pattern" "$file" || fail "$description"
}

assert_uci() {
  local command=$1 description=$2
  grep -Eq -- "^[[:space:]]*uci -q ${command}[[:space:]]*$" "$UCI" || fail "$description"
}

find_dtb_node_by_label() {
  local dtb=$1 wanted_label=$2 root=${3:-/} node child label
  local -a pending=("$root")

  while ((${#pending[@]})); do
    node=${pending[0]}
    pending=("${pending[@]:1}")
    label=$(fdtget -t s "$dtb" "$node" label 2>/dev/null || true)
    if [[ $label == "$wanted_label" ]]; then
      printf '%s\n' "$node"
      return 0
    fi
    while IFS= read -r child; do
      [[ -n $child ]] || continue
      if [[ $node == / ]]; then
        pending+=("/$child")
      else
        pending+=("$node/$child")
      fi
    done < <(fdtget -l "$dtb" "$node")
  done
  return 1
}

MANIFEST="$OPENWRT_NATIVE_CONFIG/build.json"
jq -e '
  .hostname == "bt8bridge" and
  .release == "25.12.5" and
  .target == "mediatek" and
  .subtarget == "filogic" and
  .profile == "asus_zenwifi-bt8" and
  (.profile | contains("ubootmod") | not) and
  .radiosToEnable == ["radio0", "radio1", "radio2"]
' "$MANIFEST" >/dev/null || fail "unexpected production bt8bridge manifest"

# Generate every required value from the manifest, without consulting the
# repository's encrypted secret file. Values are deliberately recognizable so
# the extracted image can prove that the secret-injection path ran.
jq '
  .secretsMap | keys |
  map({key: ., value: ("fake-native-" + .)}) |
  from_entries
' "$MANIFEST" >"$ROOT/secrets-flat.yaml"
chmod 0600 "$ROOT/secrets-flat.yaml"

mkdir "$ROOT/output"
"$OPENWRT_BUILDER" \
  --config-file "$MANIFEST" \
  --secrets-file "$ROOT/secrets-flat.yaml" \
  --output-dir "$ROOT/output"

mapfile -d '' SYSUPGRADES < <(find "$ROOT/output" -type f -name '*-sysupgrade.bin' -print0)
[[ ${#SYSUPGRADES[@]} -eq 1 ]] || fail "expected exactly one .bin sysupgrade artifact, found ${#SYSUPGRADES[@]}"
SYSUPGRADE=${SYSUPGRADES[0]}
[[ $(basename "$SYSUPGRADE") == *asus_zenwifi-bt8-squashfs-sysupgrade.bin ]] ||
  fail "sysupgrade artifact does not use the stock ASUS BT8 profile"
[[ $(basename "$SYSUPGRADE") != *ubootmod* ]] || fail "ubootmod artifact must not be produced"

PROFILES="$ROOT/output/profiles.json"
jq -e '
  .profiles["asus_zenwifi-bt8"].supported_devices |
  index("asus,zenwifi-bt8") != null
' "$PROFILES" >/dev/null || fail "profiles metadata does not support asus,zenwifi-bt8"
if jq -e '[.. | strings | select(contains("ubootmod"))] | length > 0' "$PROFILES" >/dev/null; then
  fail "profiles metadata unexpectedly references ubootmod"
fi

tar -xf "$SYSUPGRADE" -C "$ROOT"
KERNEL=$(find "$ROOT" -type f -path '*/sysupgrade-asus_zenwifi-bt8/kernel' -print -quit)
ROOTFS=$(find "$ROOT" -type f -path '*/sysupgrade-asus_zenwifi-bt8/root' -print -quit)
[[ -n $KERNEL && -n $ROOTFS ]] || fail "stock-layout sysupgrade is missing kernel or root payload"
dumpimage -l "$KERNEL" >"$ROOT/fit.txt"
assert_contains "$ROOT/fit.txt" 'asus_zenwifi-bt8 device tree blob' "FIT does not identify ASUS ZenWiFi BT8"
dumpimage -T flat_dt -p 1 -o "$ROOT/bt8.dtb" "$KERNEL" >/dev/null
[[ $(fdtget -t s "$ROOT/bt8.dtb" / compatible) == *asus,zenwifi-bt8* ]] ||
  fail "FIT device tree has the wrong compatible"
PARTITIONS=/soc/spi@11007000/spi_nand@0/partitions
[[ $(fdtget -t s "$ROOT/bt8.dtb" "$PARTITIONS" compatible) == fixed-partitions ]] ||
  fail "FIT device tree does not use a fixed-partitions stock NAND layout"
[[ $(fdtget -t s "$ROOT/bt8.dtb" "$PARTITIONS/partition@0" label) == Bootloader ]] ||
  fail "FIT device tree does not preserve the stock bootloader partition"
[[ $(fdtget -t x "$ROOT/bt8.dtb" "$PARTITIONS/partition@0" reg) == "0 400000" ]] ||
  fail "stock Bootloader partition must start at 0 and be exactly 4 MiB"
fdtget "$ROOT/bt8.dtb" "$PARTITIONS/partition@0" read-only >/dev/null 2>&1 ||
  fail "stock Bootloader partition must be read-only"
[[ $(fdtget -t s "$ROOT/bt8.dtb" "$PARTITIONS/partition@400000" label) == UBI_DEV ]] ||
  fail "FIT device tree does not use the stock UBI_DEV partition"
[[ $(fdtget -t x "$ROOT/bt8.dtb" "$PARTITIONS/partition@400000" reg) == "400000 7c00000" ]] ||
  fail "stock UBI_DEV partition must start at 4 MiB and be exactly 124 MiB"
[[ $(fdtget -t s "$ROOT/bt8.dtb" "$PARTITIONS/partition@400000" compatible) == linux,ubi ]] ||
  fail "stock UBI_DEV partition is not marked linux,ubi"

LAN1_NODE=$(find_dtb_node_by_label "$ROOT/bt8.dtb" lan1) ||
  fail "FIT device tree has no Ethernet switch port labeled lan1"
[[ $LAN1_NODE == *switch@*/ports/port@* ]] ||
  fail "lan1 is not an Ethernet switch port in the FIT device tree ($LAN1_NODE)"
LAN1_STATUS=$(fdtget -t s "$ROOT/bt8.dtb" "$LAN1_NODE" status 2>/dev/null || true)
[[ -z $LAN1_STATUS || $LAN1_STATUS == okay || $LAN1_STATUS == ok ]] ||
  fail "lan1 Ethernet switch port is disabled in the FIT device tree"

unsquashfs -d "$ROOT/rootfs" "$ROOTFS" etc >/dev/null
UCI="$ROOT/rootfs/etc/uci-defaults/99-nix-config"
[[ -x $UCI ]] || fail "/etc/uci-defaults/99-nix-config is absent or not executable"
sh -n "$UCI" || fail "99-nix-config has invalid shell syntax"

# This is the literal generated shell, not an expression to expand here.
# shellcheck disable=SC2016
assert_contains "$UCI" \
  'uci -q show network | sed -n "s/^network\.\([^.=]*\)=.*/\1/p" | while IFS= read -r section; do uci -q delete "network.$section"; done' \
  "99-nix-config does not delete every built-in named and anonymous network section"
assert_contains "$UCI" 'while uci -q delete wireless.@wifi-iface[-1]; do :; done' \
  "99-nix-config does not clean up built-in wireless interfaces"
assert_contains "$UCI" "uci -q set network.br_mgmt.name='br-mgmt'" "br-mgmt is not configured"
assert_contains "$UCI" "uci -q add_list network.br_mgmt.ports='lan1'" "LAN1 recovery port is not in br-mgmt"
assert_contains "$UCI" "uci -q set network.mgmt.device='br-mgmt'" "management interface does not use br-mgmt"
assert_contains "$UCI" "uci -q set network.mgmt.ipaddr='10.91.10.4'" "management address is incorrect"

NETWORK_CLEANUP_LINE=$(grep -nF 'uci -q show network | sed -n' "$UCI" | head -n1 | cut -d: -f1)
BR_MGMT_LINE=$(grep -nF "uci -q set network.br_mgmt.name='br-mgmt'" "$UCI" | head -n1 | cut -d: -f1)
[[ -n $NETWORK_CLEANUP_LINE && -n $BR_MGMT_LINE && $NETWORK_CLEANUP_LINE -lt $BR_MGMT_LINE ]] ||
  fail "built-in network cleanup must occur before br-mgmt is created"

# Inspect the generated first-boot UCI program. The x86 deployer VM provides
# complementary behavioral coverage by executing this cleanup and testing
# connectivity; this native check validates the exact BT8 artifact statically.
assert_uci "set dropbear\.main=.?dropbear.?" "generated Dropbear instance is absent"
assert_uci "set dropbear\.main\.Port=.?22.?" "Dropbear does not listen on port 22"
assert_uci "set dropbear\.main\.PasswordAuth=.?0.?" "Dropbear password authentication is not disabled"
assert_uci "set dropbear\.main\.RootPasswordAuth=.?0.?" "Dropbear root-password authentication is not disabled"
find "$ROOT/rootfs/etc/rc.d" -maxdepth 1 -type l -name 'S*dropbear' -print -quit | grep -q . ||
  fail "Dropbear init service is not enabled in the native image"
assert_uci "set firewall\.mgmt=.?zone.?" "management firewall zone is absent"
assert_uci "set firewall\.mgmt\.name=.?mgmt.?" "management firewall zone has the wrong name"
assert_uci "add_list firewall\.mgmt\.network=.?mgmt.?" "management interface is absent from its firewall zone"
assert_uci "set firewall\.allow_admin=.?rule.?" "management services firewall rule is absent"
assert_uci "set firewall\.allow_admin\.src=.?mgmt.?" "management services rule is not scoped to the management zone"
assert_uci "add_list firewall\.allow_admin\.src_ip=.?10\.91\.10\.0/24.?" "recovery subnet is absent from the management services rule"
assert_uci "add_list firewall\.allow_admin\.src_ip=.?10\.97\.20\.0/24.?" "routed admin subnet is absent from the management services rule"
assert_uci "set firewall\.allow_admin\.proto=.?tcp.?" "management services rule is not TCP-only"
assert_uci "add_list firewall\.allow_admin\.dest_port=.?22.?" "SSH port 22 is absent from the management services rule"
assert_uci "set firewall\.allow_admin\.target=.?ACCEPT.?" "management services rule does not accept traffic"

for radio in radio0 radio1 radio2; do
  assert_contains "$UCI" "uci -q set wireless.$radio.disabled=0" "$radio was not enabled by fake-secret injection"
done
while IFS= read -r secret_key; do
  assert_contains "$UCI" "fake-native-$secret_key" "fake value for $secret_key was not injected"
done < <(jq -r '.secretsMap | keys[]' "$MANIFEST")

EXPECTED_KEYS=$(jq -r '.authorizedKeys' "$MANIFEST")
cmp "$EXPECTED_KEYS" "$ROOT/rootfs/etc/dropbear/authorized_keys" >/dev/null ||
  fail "authorized keys do not match the evaluated production manifest"
[[ -s "$ROOT/rootfs/etc/dropbear/authorized_keys" ]] || fail "authorized keys are empty"

IMAGE_PACKAGES=$(find "$ROOT/output" -maxdepth 1 -type f -name '*.manifest' -print -quit)
[[ -n $IMAGE_PACKAGES ]] || fail "ImageBuilder package manifest is missing"
for package in \
  dropbear firewall4 kmod-batman-adv batctl-full wpad-mesh-openssl \
  kmod-mt7996-firmware mt7988-2p5g-phy-firmware mt7988-wo-firmware; do
  grep -Eq "^${package}[[:space:]]" "$IMAGE_PACKAGES" || fail "required package $package is absent"
done

echo "Native BT8 image check passed: $(basename "$SYSUPGRADE")"
