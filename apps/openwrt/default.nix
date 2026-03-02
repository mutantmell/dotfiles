# OpenWrt management apps
#
# Build:
#   nix run .#openwrt-build -- <device-name>
#   nix run .#openwrt-build -- <device-name> --no-secrets
#
# Update Image Builder hashes (modifies lib/common/data/openwrt.nix):
#   nix run .#openwrt-build -- --update-pins            (all targets)
#   nix run .#openwrt-build -- <device-name> --update-pins  (one target)
#   nix run .#openwrt-build -- <device-name> --update   (update + build)
#
# Deploy:
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
#
# Discovery:
#   nix run .#openwrt-show-config -- <device-name>
#   nix run .#openwrt-build -- --list-devices
#
# Migration (from existing devices):
#   nix run .#openwrt-export-config -- <device-ip> [output-dir]
#   nix run .#openwrt-analyze-packages -- <device-ip>
#
# Local analysis (from exported configs):
#   nix run .#openwrt-analyze-local -- <config-dir-or-uci-file>
#
# Secrets file format (hosts/openwrt/secrets/wifi.yaml):
#   mesh_id: "your-mesh-id"
#   mesh_key: "your-mesh-password"
#   wifi_ssids:
#     main: "NetworkName"
#     secondary: "NetworkName-Alt"
#     iot: "NetworkName-IoT"
#   wifi_keys:
#     main: "main-network-password"
#     secondary: "alt-network-password"
#     iot: "iot-network-password"
{ pkgs, openwrtDevices, openwrtConfigurations }:

let
  lib = pkgs.lib;
  builder = pkgs.mmell.openwrt-builder;
  deployer = pkgs.mmell.openwrt-deployer;

  # Device name → config dir lookup (shell case statement)
  # ${drv} interpolation embeds the store path AND adds drv to the closure,
  # so all openwrtConfigurations derivations are built before these scripts run.
  deviceConfigLookup = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: drv:
    "    ${name}) CONFIG_DIR=\"${drv}\" ;;"
  ) openwrtConfigurations);

  # Device name → target/subtarget lookup (for update flow)
  deviceTargetLookup = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: device:
    "    ${name}) DEVICE_TARGET=\"${device.target}/${device.subtarget}\" ;;"
  ) openwrtDevices);

  # Space-separated list of all unique targets across all devices (for --update-pins)
  allTargets = lib.concatStringsSep " " (
    lib.unique (lib.mapAttrsToList (_: device: "${device.target}/${device.subtarget}") openwrtDevices)
  );

  # Device listing info embedded at eval time
  deviceListInfo = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: device:
    "  printf '  %-20s %-10s %s\\n' '${name}' '${device.type}' '${device.profile}'"
  ) openwrtDevices);

  # Resolve device name to CONFIG_DIR, or error
  resolveDevice = ''
    resolve_device() {
      local DEVICE="$1"
      CONFIG_DIR=""
      case "$DEVICE" in
    ${deviceConfigLookup}
        *)
          echo "Error: Unknown device '$DEVICE'" >&2
          echo "Available devices:" >&2
    ${deviceListInfo}
          exit 1
          ;;
      esac
    }
  '';

  # Resolve device name to DEVICE_TARGET (target/subtarget), or error
  resolveTarget = ''
    resolve_target() {
      local DEVICE="$1"
      DEVICE_TARGET=""
      case "$DEVICE" in
    ${deviceTargetLookup}
        *)
          echo "Error: Unknown device '$DEVICE'" >&2
          exit 1
          ;;
      esac
    }
  '';

  # Discover the secrets file from the repo (convenience for app wrappers)
  discoverSecrets = ''
    SECRETS_ARGS=""
    if [ -n "$REPO_ROOT" ]; then
      SECRETS_FILE="$REPO_ROOT/hosts/openwrt/secrets/wifi.yaml"
      if [ -f "$SECRETS_FILE" ]; then
        SECRETS_ARGS="--secrets-file $SECRETS_FILE"
      fi
    fi
  '';

in {
  # Build an OpenWrt image using the upstream Image Builder
  openwrt-build = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-build-wrapper" ''
        set -euo pipefail

        ${resolveDevice}
        ${resolveTarget}

        # Always resolve repo root — needed for secrets and update paths
        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")

        # Handle --list-devices before anything else
        for arg in "$@"; do
          if [ "$arg" = "--list-devices" ]; then
            echo "Available devices:"
        ${deviceListInfo}
            exit 0
          fi
        done

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-build -- <device-name> [--no-secrets] [--update]"
          echo "       nix run .#openwrt-build -- <device-name> --update-pins"
          echo "       nix run .#openwrt-build -- --update-pins  (all targets)"
          echo "       nix run .#openwrt-build -- --config-dir <dir> [--secrets-file <file>]"
          echo "       nix run .#openwrt-build -- --list-devices"
          exit 1
        fi

        # --- Parse and strip update flags from positional args ---
        DO_UPDATE=false
        UPDATE_ONLY=false
        UPDATE_RELEASE_ARG=""
        CLEAN_ARGS=()
        i=0
        ALL_ARGS=("$@")
        while [ $i -lt ''${#ALL_ARGS[@]} ]; do
          arg="''${ALL_ARGS[$i]}"
          case "$arg" in
            --update)      DO_UPDATE=true ;;
            --update-pins) UPDATE_ONLY=true ;;
            --release)
              i=$((i + 1))
              UPDATE_RELEASE_ARG="''${ALL_ARGS[$i]}"
              ;;
            *) CLEAN_ARGS+=("$arg") ;;
          esac
          i=$((i + 1))
        done

        # --- Update flow (--update or --update-pins) ---
        if $DO_UPDATE || $UPDATE_ONLY; then
          if [ -z "$REPO_ROOT" ]; then
            echo "Error: --update/--update-pins requires running from within the git repo" >&2
            exit 1
          fi
          HASHES_FILE="$REPO_ROOT/lib/common/data/openwrt-hashes.json"

          # Determine which targets to update
          if [ ''${#CLEAN_ARGS[@]} -ge 1 ] && [ "''${CLEAN_ARGS[0]#--}" = "''${CLEAN_ARGS[0]}" ]; then
            # First clean arg is a device name (doesn't start with --)
            resolve_target "''${CLEAN_ARGS[0]}"
            UPDATE_TARGETS="$DEVICE_TARGET"
          else
            # No device specified — update all targets
            UPDATE_TARGETS="${allTargets}"
          fi

          RELEASE_ARGS=()
          if [ -n "$UPDATE_RELEASE_ARG" ]; then
            RELEASE_ARGS=(--release "$UPDATE_RELEASE_ARG")
          fi

          echo "Updating Image Builder hashes (targets: $UPDATE_TARGETS)..."
          ${builder}/bin/openwrt-build \
            --update-pins \
            --hashes-file "$HASHES_FILE" \
            --targets $UPDATE_TARGETS \
            "''${RELEASE_ARGS[@]}"

          if $UPDATE_ONLY; then
            exit 0
          fi

          # --update + build: re-evaluate the config with the new hashes
          DEVICE="''${CLEAN_ARGS[0]}"
          echo "Re-evaluating Nix config for $DEVICE..."
          CONFIG_DIR=$(${pkgs.nix}/bin/nix build ".#openwrtConfigurations.$DEVICE" \
            --print-out-paths --no-link)
        fi

        # Restore cleaned args (update flags removed)
        set -- "''${CLEAN_ARGS[@]}"

        # --config-dir mode: use a pre-built manifest directory directly
        if [ "''${1:-}" = "--config-dir" ]; then
          shift
          ${discoverSecrets}
          exec ${builder}/bin/openwrt-build --config-dir "$@" $SECRETS_ARGS
        fi

        DEVICE="$1"
        shift

        if ! $DO_UPDATE; then
          # CONFIG_DIR not yet set by update flow — resolve from pre-built configs
          resolve_device "$DEVICE"
        fi

        ${discoverSecrets}
        DEFAULT_OUTPUT_DIR="''${REPO_ROOT:+$REPO_ROOT/openwrt-images/$DEVICE}"
        OUTPUT_DIR_ARG=""
        if [ -n "$DEFAULT_OUTPUT_DIR" ]; then
          OUTPUT_DIR_ARG="--output-dir $DEFAULT_OUTPUT_DIR"
        fi
        exec ${builder}/bin/openwrt-build --config-dir "$CONFIG_DIR" $SECRETS_ARGS $OUTPUT_DIR_ARG "$@"
      '';
    in "${script}";
  };

  # Deploy an OpenWrt image to a device via sysupgrade
  openwrt-deploy = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-deploy" ''
        set -euo pipefail

        ${resolveDevice}

        if [ $# -lt 2 ]; then
          echo "Usage: nix run .#openwrt-deploy -- <device-name> <device-ip> [--force] [--no-secrets]"
          echo ""
          echo "Builds and deploys an OpenWrt sysupgrade image to the specified device."
          echo "Secrets are baked into the image — no post-deploy SSH step needed."
          echo ""
          echo "Arguments:"
          echo "  device-name    Name of the device (as defined in hosts/openwrt/)"
          echo "  device-ip      IP address or hostname of the device"
          echo "  --force        Skip confirmation prompt"
          echo "  --no-secrets   Build without WiFi secrets (radios will be disabled)"
          echo ""
          echo "Example:"
          echo "  nix run .#openwrt-deploy -- bobcat 10.0.10.10"
          exit 1
        fi

        DEVICE="$1"
        TARGET="$2"
        shift 2
        resolve_device "$DEVICE"

        BUILD_ARGS=""
        DEPLOY_ARGS=""
        for arg in "$@"; do
          case "$arg" in
            --force) DEPLOY_ARGS="$DEPLOY_ARGS --force" ;;
            --no-secrets) BUILD_ARGS="$BUILD_ARGS --no-secrets" ;;
          esac
        done

        ${discoverSecrets}

        OUTPUT_DIR="''${REPO_ROOT:+$REPO_ROOT/openwrt-images/$DEVICE}"
        OUTPUT_DIR="''${OUTPUT_DIR:-$(pwd)/openwrt-images/$DEVICE}"

        # Build the image
        ${builder}/bin/openwrt-build \
          --config-dir "$CONFIG_DIR" \
          --output-dir "$OUTPUT_DIR" \
          $SECRETS_ARGS \
          $BUILD_ARGS

        # Find the sysupgrade image
        SYSUPGRADE=$(find "$OUTPUT_DIR" -name "*-sysupgrade.bin" -o -name "*-sysupgrade.img.gz" | head -1)

        if [ -z "$SYSUPGRADE" ]; then
          echo "Error: No sysupgrade image found in $OUTPUT_DIR"
          exit 1
        fi

        # Deploy the image
        ${deployer}/bin/openwrt-deploy "$TARGET" "$SYSUPGRADE" $DEPLOY_ARGS
      '';
    in "${script}";
  };

  # Show UCI configuration that would be applied
  openwrt-show-config = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-show-config" ''
        set -euo pipefail

        ${resolveDevice}

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-show-config -- <device-name>"
          echo ""
          echo "Shows the UCI configuration that would be applied to the device."
          exit 1
        fi

        resolve_device "$1"
        cat "$CONFIG_DIR/uci-defaults.sh"
      '';
    in "${script}";
  };

  # Export configuration from an existing OpenWrt device
  openwrt-export-config = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-export-config" ''
        set -euo pipefail

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-export-config -- <device-ip> [output-dir]"
          echo ""
          echo "Exports UCI configuration from an existing OpenWrt device."
          echo "Useful for migrating existing devices to the declarative system."
          echo ""
          echo "Output includes:"
          echo "  - uci-show.txt     - Full UCI config (keys redacted)"
          echo "  - packages.txt     - Installed packages"
          echo "  - device-info.txt  - Board, model, version info"
          exit 1
        fi

        TARGET="$1"
        OUTPUT_DIR="''${2:-.}"

        echo "Exporting configuration from $TARGET..."
        mkdir -p "$OUTPUT_DIR"

        # Device info
        echo "  - Device info..."
        ${pkgs.openssh}/bin/ssh "root@$TARGET" "
          echo '=== Board ==='
          cat /tmp/sysinfo/board_name 2>/dev/null || echo 'unknown'
          echo
          echo '=== Model ==='
          cat /tmp/sysinfo/model 2>/dev/null || echo 'unknown'
          echo
          echo '=== OpenWrt Version ==='
          cat /etc/openwrt_release
          echo
          echo '=== Kernel ==='
          uname -a
        " > "$OUTPUT_DIR/device-info.txt"

        # Full UCI config (redact keys)
        echo "  - Full UCI config..."
        ${pkgs.openssh}/bin/ssh "root@$TARGET" "uci show" | \
          ${pkgs.gnused}/bin/sed "s/\(\.key='\)[^']*'/\1[REDACTED]'/g" > "$OUTPUT_DIR/uci-show.txt"

        # Installed packages
        echo "  - Installed packages..."
        ${pkgs.openssh}/bin/ssh "root@$TARGET" "opkg list-installed" > "$OUTPUT_DIR/packages.txt"

        echo
        echo "Configuration exported to $OUTPUT_DIR/"
        echo
        echo "Files created:"
        ls -la "$OUTPUT_DIR"/*.txt
      '';
    in "${script}";
  };

  # Analyze packages on an existing device to find minimal set
  openwrt-analyze-packages = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-analyze-packages" ''
        set -euo pipefail

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-analyze-packages -- <device-ip>"
          echo ""
          echo "Analyzes installed packages on an OpenWrt device to help determine"
          echo "a minimal package set for migration."
          echo ""
          echo "Shows:"
          echo "  - User-installed packages (not dependencies)"
          echo "  - Packages related to mesh/batman-adv"
          echo "  - Packages related to wireless"
          echo "  - Suggested extraPackages for your Nix config"
          exit 1
        fi

        TARGET="$1"

        echo "Analyzing packages on $TARGET..."
        echo ""

        # Get all installed packages
        PACKAGES=$(${pkgs.openssh}/bin/ssh "root@$TARGET" "opkg list-installed" | cut -d' ' -f1)

        # Get user-installed packages (packages that were explicitly installed, not deps)
        echo "=== User-Installed Packages ==="
        echo "(These were explicitly installed, not pulled in as dependencies)"
        echo ""
        ${pkgs.openssh}/bin/ssh "root@$TARGET" "
          # Packages in /usr/lib/opkg/status with 'Status: install user installed'
          awk '/^Package:/{pkg=\$2} /^Status:.*user installed/{print pkg}' /usr/lib/opkg/status | sort
        " || echo "(Could not determine user-installed packages)"
        echo ""

        # Mesh-related packages
        echo "=== Mesh/Batman-adv Packages ==="
        echo "$PACKAGES" | grep -E '(batman|mesh|batctl)' || echo "(none found)"
        echo ""

        # Wireless packages
        echo "=== Wireless Packages ==="
        echo "$PACKAGES" | grep -E '(wpad|hostapd|wireless|wifi|80211)' || echo "(none found)"
        echo ""

        # LuCI packages
        echo "=== LuCI Packages ==="
        echo "$PACKAGES" | grep -E '^luci' || echo "(none found)"
        echo ""

        # Kernel modules
        echo "=== Kernel Modules (kmod-*) ==="
        echo "$PACKAGES" | grep '^kmod-' | grep -v -E '(kmod-lib|kmod-crypto|kmod-nf-|kmod-ipt-)' || echo "(none found)"
        echo ""

        # Generate suggested extraPackages
        echo "=== Suggested extraPackages for Nix config ==="
        echo ""
        echo "Based on analysis, consider adding these to extraPackages:"
        echo ""
        echo "extraPackages = ["

        # User-installed that aren't in our defaults
        ${pkgs.openssh}/bin/ssh "root@$TARGET" "
          awk '/^Package:/{pkg=\$2} /^Status:.*user installed/{print pkg}' /usr/lib/opkg/status
        " 2>/dev/null | while read -r pkg; do
          # Skip packages we already include by default
          case "$pkg" in
            kmod-batman-adv|batctl*|wpad*|luci|luci-proto-batman-adv|htop|tcpdump|kmod-8021q)
              continue
              ;;
            *)
              echo "  \"$pkg\""
              ;;
          esac
        done

        echo "];"
        echo ""
        echo "Note: Review this list - some packages may be dependencies or device-specific."
      '';
    in "${script}";
  };

  # Analyze local config exports to detect features and infer packages
  openwrt-analyze-local = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-analyze-local" ''
        set -euo pipefail

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-analyze-local -- <config-dir-or-uci-file>"
          echo ""
          echo "Analyzes exported OpenWrt configuration to detect features,"
          echo "infer a minimal package set, and suggest Nix config."
          echo ""
          echo "Accepts either:"
          echo "  - A config directory (e.g., temp/openwrt/config/<device>/config/)"
          echo "  - A UCI export file (e.g., temp/openwrt/uci/<device>.uci)"
          echo ""
          echo "Examples:"
          echo "  nix run .#openwrt-analyze-local -- temp/openwrt/config/derfflinger/config"
          echo "  nix run .#openwrt-analyze-local -- temp/openwrt/uci/arseille.uci"
          exit 1
        fi

        INPUT="$1"
        UCI_DATA=""

        # Convert raw UCI config files to UCI-show format
        # Handles: config <type> '<name>' / option <key> '<value>' / list <key> '<value>'
        convert_config_dir() {
          local dir="$1"
          for f in "$dir"/*; do
            [ -f "$f" ] || continue
            local fname
            fname=$(basename "$f")
            local section_type="" section_name="" anon_idx=0
            while IFS= read -r line; do
              # Skip empty lines and comments
              case "$line" in
                ""|\#*) continue ;;
              esac
              # Strip leading whitespace
              line=$(echo "$line" | sed 's/^[[:space:]]*//')
              case "$line" in
                "config "*)
                  # Parse: config <type> '<name>' or config <type>
                  section_type=$(echo "$line" | ${pkgs.gawk}/bin/awk '{print $2}')
                  section_name=$(echo "$line" | ${pkgs.gnused}/bin/sed -n "s/^config [^ ]* '\(.*\)'/\1/p")
                  if [ -z "$section_name" ]; then
                    section_name="@$section_type[$anon_idx]"
                    anon_idx=$((anon_idx + 1))
                  fi
                  echo "$fname.$section_name=$section_type"
                  ;;
                "option "*)
                  local key val
                  key=$(echo "$line" | ${pkgs.gawk}/bin/awk '{print $2}')
                  val=$(echo "$line" | ${pkgs.gnused}/bin/sed -n "s/^option [^ ]* '\(.*\)'/\1/p")
                  if [ -z "$val" ]; then
                    val=$(echo "$line" | ${pkgs.gawk}/bin/awk '{print $3}')
                  fi
                  echo "$fname.$section_name.$key='$val'"
                  ;;
                "list "*)
                  local key val
                  key=$(echo "$line" | ${pkgs.gawk}/bin/awk '{print $2}')
                  val=$(echo "$line" | ${pkgs.gnused}/bin/sed -n "s/^list [^ ]* '\(.*\)'/\1/p")
                  if [ -z "$val" ]; then
                    val=$(echo "$line" | ${pkgs.gawk}/bin/awk '{print $3}')
                  fi
                  echo "$fname.$section_name.$key='$val'"
                  ;;
              esac
            done < "$f"
          done
        }

        # Determine input type and load UCI data
        if [ -f "$INPUT" ]; then
          # Single UCI export file
          UCI_DATA=$(cat "$INPUT")
          DEVICE=$(basename "$INPUT" .uci)
          echo "Analyzing UCI export: $INPUT"
        elif [ -d "$INPUT" ]; then
          # Config directory — convert raw config to UCI-show format
          CONFIG_DIR="$INPUT"
          if [ -d "$CONFIG_DIR/config" ]; then
            CONFIG_DIR="$CONFIG_DIR/config"
          fi
          DEVICE=$(basename "$(cd "$INPUT" && pwd)")
          if [ "$DEVICE" = "config" ]; then
            DEVICE=$(basename "$(cd "$INPUT/.." && pwd)")
          fi
          echo "Analyzing config directory: $CONFIG_DIR"
          UCI_DATA=$(convert_config_dir "$CONFIG_DIR")
        else
          echo "Error: $INPUT is not a file or directory"
          exit 1
        fi

        echo "Device: $DEVICE"
        echo ""

        # Feature detection functions (always use UCI_DATA)
        has_feature() {
          echo "$UCI_DATA" | grep -q "$1" 2>/dev/null
        }

        get_value() {
          echo "$UCI_DATA" | grep "$1" 2>/dev/null | head -1 | sed "s/.*='\(.*\)'/\1/" || true
        }

        get_all() {
          echo "$UCI_DATA" | grep "$1" 2>/dev/null || true
        }

        # --- Feature Detection ---
        echo "=== Detected Features ==="
        echo ""

        FEATURES=""

        # Batman-adv mesh
        if has_feature "proto.*batadv"; then
          echo "  [x] batman-adv mesh networking"
          FEATURES="$FEATURES batman"
        else
          echo "  [ ] batman-adv mesh networking"
        fi

        # Wireless mesh
        if has_feature "mode.*mesh"; then
          echo "  [x] Wireless mesh (802.11s)"
          FEATURES="$FEATURES wireless-mesh"
          MESH_ID=$(get_value "mesh_id=")
          if [ -n "$MESH_ID" ]; then
            echo "       mesh_id: $MESH_ID"
          fi
        else
          echo "  [ ] Wireless mesh (802.11s)"
        fi

        # VLANs on bat0
        if has_feature "bat0\.[0-9]"; then
          echo "  [x] VLAN interfaces on bat0"
          FEATURES="$FEATURES vlans"
          echo "       VLANs:"
          get_all "bat0\.[0-9]" | grep -oE "bat0\.[0-9]+" | sort -u | sed 's/^/         /'
        else
          echo "  [ ] VLAN interfaces on bat0"
        fi

        # Bridge VLANs (switch-style)
        if has_feature "bridge-vlan"; then
          echo "  [x] Bridge VLAN filtering (managed switch)"
          FEATURES="$FEATURES bridge-vlans"
          echo "       VLANs:"
          get_all "\.vlan=" | sed -n "s/.*\.vlan='\([0-9]*\)'/         VLAN \1/p" | sort -u
        fi

        # LuCI
        if has_feature "^luci\."; then
          echo "  [x] LuCI web UI"
          FEATURES="$FEATURES luci"
        else
          echo "  [ ] LuCI web UI"
        fi

        # Usteer
        if has_feature "^usteer\."; then
          echo "  [x] usteer (WiFi steering)"
          FEATURES="$FEATURES usteer"
        else
          echo "  [ ] usteer (WiFi steering)"
        fi

        # Firewall
        if has_feature "^firewall\."; then
          echo "  [x] Firewall (firewall4/nftables)"
          FEATURES="$FEATURES firewall"
        else
          echo "  [ ] Firewall"
        fi

        # Wireless
        HAS_WIRELESS=""
        if has_feature "^wireless\."; then
          echo "  [x] Wireless"
          HAS_WIRELESS=1

          # 802.11r
          if has_feature "ieee80211r"; then
            echo "  [x] 802.11r fast roaming"
            FEATURES="$FEATURES 80211r"
          fi

          # 802.11k
          if has_feature "ieee80211k"; then
            echo "  [x] 802.11k radio resource management"
            FEATURES="$FEATURES 80211k"
          fi

          # HE BSS color
          BSS_COLOR=$(get_value "he_bss_color=")
          if [ -n "$BSS_COLOR" ]; then
            echo "  [x] HE BSS color: $BSS_COLOR"
          fi

          # Legacy rates
          if has_feature "legacy_rates.*1"; then
            echo "  [x] Legacy rates enabled"
            FEATURES="$FEATURES legacy-rates"
          fi

          # Country code
          COUNTRY=$(get_value "\.country=")
          if [ -n "$COUNTRY" ]; then
            echo "       Country: $COUNTRY"
          fi

          # SSIDs
          echo "       SSIDs:"
          get_all "\.ssid=" | sed "s/.*\.ssid='\(.*\)'/         \1/" | sort -u
        else
          echo "  [ ] Wireless (wired-only device)"
        fi

        echo ""

        # --- Network Summary ---
        echo "=== Network Summary ==="
        echo ""

        # Hostname
        HOSTNAME=$(get_value "\.hostname=")
        echo "  Hostname: $HOSTNAME"

        # IP addresses
        echo "  IP Addresses:"
        get_all "\.ipaddr=" | grep -v "127.0.0.1" | sed "s/.*\.\(.*\)\.ipaddr='\(.*\)'/    \1: \2/"

        # Gateways
        echo "  Gateways:"
        get_all "\.gateway=" | sed "s/.*\.\(.*\)\.gateway='\(.*\)'/    \1: \2/"

        echo ""

        # --- Inferred Package Set ---
        echo "=== Inferred Package Set ==="
        echo ""

        PACKAGES=""
        REMOVE_PACKAGES=""

        # Base packages for all devices
        echo "  Remove from defaults:"
        echo "    -dnsmasq"
        echo "    -odhcpd-ipv6only"
        echo "    -ppp"
        echo "    -ppp-mod-pppoe"
        REMOVE_PACKAGES="-dnsmasq -odhcpd-ipv6only -ppp -ppp-mod-pppoe"

        case "$FEATURES" in
          *batman*)
            echo ""
            echo "  Mesh packages:"
            echo "    kmod-batman-adv"
            echo "    batctl-full"
            PACKAGES="$PACKAGES kmod-batman-adv batctl-full"
            ;;
        esac

        case "$FEATURES" in
          *wireless-mesh*)
            echo "    wpad-mesh-openssl"
            PACKAGES="$PACKAGES wpad-mesh-openssl"
            REMOVE_PACKAGES="$REMOVE_PACKAGES -wpad-basic-mbedtls"
            echo "    (replaces wpad-basic-mbedtls)"
            ;;
        esac

        case "$FEATURES" in
          *vlans*|*bridge-vlans*)
            echo ""
            echo "  VLAN support:"
            echo "    kmod-8021q"
            PACKAGES="$PACKAGES kmod-8021q"
            ;;
        esac

        case "$FEATURES" in
          *luci*)
            echo ""
            echo "  LuCI packages:"
            echo "    luci"
            PACKAGES="$PACKAGES luci"
            case "$FEATURES" in
              *batman*)
                echo "    luci-proto-batman-adv"
                PACKAGES="$PACKAGES luci-proto-batman-adv"
                ;;
            esac
            ;;
        esac

        case "$FEATURES" in
          *usteer*)
            echo ""
            echo "  WiFi steering:"
            echo "    usteer"
            PACKAGES="$PACKAGES usteer"
            ;;
        esac

        case "$FEATURES" in
          *firewall*)
            # If it's a switch or has firewall, keep firewall packages
            case "$FEATURES" in
              *batman*)
                echo ""
                echo "  Firewall: REMOVE (mesh AP, not needed)"
                REMOVE_PACKAGES="$REMOVE_PACKAGES -firewall4 -nftables"
                ;;
              *)
                echo ""
                echo "  Firewall: KEEP (switch/AP device)"
                ;;
            esac
            ;;
        esac

        if [ -z "$HAS_WIRELESS" ]; then
          echo ""
          echo "  No wireless: remove wpad-*"
          REMOVE_PACKAGES="$REMOVE_PACKAGES -wpad-basic-mbedtls"
        fi

        echo ""
        echo "  Debug tools:"
        echo "    htop"
        echo "    tcpdump"

        echo ""

        # --- Suggested Nix Config ---
        echo "=== Suggested Nix Configuration ==="
        echo ""

        # Determine device type
        DEVICE_TYPE="unknown"
        case "$FEATURES" in
          *batman*wireless-mesh*)
            DEVICE_TYPE="meshAP"
            ;;
          *bridge-vlans*)
            DEVICE_TYPE="switch"
            ;;
        esac

        if [ -n "$HAS_WIRELESS" ] && [ "$DEVICE_TYPE" = "unknown" ]; then
          DEVICE_TYPE="simpleAP"
        fi

        LAN_ADDR=$(get_value "\.lan\.ipaddr=" | head -1)
        MGMT_ADDR=$(get_value "\.mgmt\.ipaddr=" | head -1)

        case "$DEVICE_TYPE" in
          meshAP)
            echo "$DEVICE = mkMeshAP {"
            echo "  hostname = \"$DEVICE\";"
            echo "  profile = \"linksys_e8450-ubi\";"
            if [ -n "$LAN_ADDR" ]; then
              echo "  lanAddress = \"$LAN_ADDR\";"
            fi
            if [ -n "$MGMT_ADDR" ]; then
              echo "  mgmtAddress = \"$MGMT_ADDR\";"
            fi
            # Per-device extras
            BSS_COLOR=$(get_value "he_bss_color=")
            if [ -n "$BSS_COLOR" ]; then
              echo "  extraConfig.wireless.radio1.he_bss_color = $BSS_COLOR;"
            fi
            if echo "$FEATURES" | grep -q "legacy-rates"; then
              echo "  extraConfig.wireless.radio0.legacy_rates = true;"
            fi
            if echo "$FEATURES" | grep -q "usteer"; then
              echo "  extraPackages = [ \"usteer\" ];"
            fi
            # IoT VLAN
            if has_feature "bat0\.1040"; then
              echo "  # Has IoT VLAN (bat0.1040) with separate IoT SSID"
            fi
            echo "};"
            ;;
          switch)
            echo "$DEVICE = mkSwitch {"
            echo "  hostname = \"$DEVICE\";"
            echo "  profile = \"linksys_e8450-ubi\";"
            if [ -n "$LAN_ADDR" ]; then
              echo "  lanAddress = \"$LAN_ADDR\";"
            fi
            echo "  extraPackages = openwrt.packages.luciPackages;"
            echo "};"
            ;;
          simpleAP)
            SSID=$(get_value "\.ssid=")
            echo "$DEVICE = mkSimpleAP {"
            echo "  hostname = \"$DEVICE\";"
            echo "  profile = \"TODO\";  # Unknown hardware"
            if [ -n "$LAN_ADDR" ]; then
              echo "  lanAddress = \"$LAN_ADDR\";"
            fi
            if [ -n "$SSID" ]; then
              echo "  ssid = \"$SSID\";"
            fi
            echo "};"
            ;;
          *)
            echo "# Could not determine device type for $DEVICE"
            echo "# Features: $FEATURES"
            ;;
        esac
      '';
    in "${script}";
  };
}
