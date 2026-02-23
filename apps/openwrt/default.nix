# OpenWrt management apps
#
# Deployment:
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
#   nix run .#openwrt-configure-secrets -- <device-ip>
#
# Discovery:
#   nix run .#openwrt-profiles -- | grep -i <device>
#   nix run .#openwrt-show-config -- <device-name>
#
# Migration (from existing devices):
#   nix run .#openwrt-export-config -- <device-ip> [output-dir]
#   nix run .#openwrt-analyze-packages -- <device-ip>
#
# Local analysis (from exported configs):
#   nix run .#openwrt-analyze-local -- <config-dir-or-uci-file>
#
# Secrets file format (hosts/openwrt/secrets/wifi.yaml):
#   mesh_key: "your-mesh-password"
#   wifi_keys:
#     main: "main-network-password"
#     guest: "guest-network-password"
#     iot: "iot-network-password"
{ pkgs }:

let
  # Script to configure secrets on an OpenWrt device via SSH
  # Reads from sops-encrypted hosts/openwrt/secrets/wifi.yaml
  configureSecretsScript = pkgs.writeShellScript "openwrt-configure-secrets" ''
    set -euo pipefail

    TARGET="$1"
    REPO_ROOT="''${2:-$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")}"

    if [ -z "$TARGET" ]; then
      echo "Usage: openwrt-configure-secrets <device-ip> [repo-root]"
      exit 1
    fi

    if [ -z "$REPO_ROOT" ]; then
      echo "Error: Could not find repository root. Please specify it as the second argument."
      exit 1
    fi

    SECRETS_FILE="$REPO_ROOT/hosts/openwrt/secrets/wifi.yaml"

    if [ ! -f "$SECRETS_FILE" ]; then
      echo "No secrets file found at $SECRETS_FILE"
      echo "Skipping secrets configuration."
      echo ""
      echo "To create one, run:"
      echo "  sops $SECRETS_FILE"
      echo ""
      echo "Expected format:"
      echo "  mesh_key: \"your-mesh-password\""
      echo "  wifi_keys:"
      echo "    main: \"main-network-password\""
      echo "    guest: \"guest-network-password\""
      exit 0
    fi

    echo "Decrypting secrets..."
    SECRETS=$(${pkgs.sops}/bin/sops -d "$SECRETS_FILE")

    # Extract values using yq
    MESH_KEY=$(echo "$SECRETS" | ${pkgs.yq-go}/bin/yq -r '.mesh_key // empty')
    WIFI_MAIN=$(echo "$SECRETS" | ${pkgs.yq-go}/bin/yq -r '.wifi_keys.main // empty')
    WIFI_GUEST=$(echo "$SECRETS" | ${pkgs.yq-go}/bin/yq -r '.wifi_keys.guest // empty')
    WIFI_IOT=$(echo "$SECRETS" | ${pkgs.yq-go}/bin/yq -r '.wifi_keys.iot // empty')

    echo "Configuring secrets on $TARGET..."

    # Build UCI commands
    UCI_COMMANDS=""

    # Configure mesh key on all mesh interfaces
    if [ -n "$MESH_KEY" ]; then
      echo "  - Setting mesh key..."
      UCI_COMMANDS="$UCI_COMMANDS
    for i in \$(uci show wireless | grep \"mode='mesh'\" | cut -d. -f2); do
      uci set wireless.\$i.encryption='sae'
      uci set wireless.\$i.key='$MESH_KEY'
    done"
    fi

    # Configure wifi keys by SSID pattern matching
    if [ -n "$WIFI_MAIN" ]; then
      echo "  - Setting main network key..."
      UCI_COMMANDS="$UCI_COMMANDS
    for i in \$(uci show wireless | grep -E \"ssid='.*(Network|Home).*'\" | grep -v Guest | grep -v IoT | cut -d. -f2); do
      uci set wireless.\$i.key='$WIFI_MAIN'
    done"
    fi

    if [ -n "$WIFI_GUEST" ]; then
      echo "  - Setting guest network key..."
      UCI_COMMANDS="$UCI_COMMANDS
    for i in \$(uci show wireless | grep -i \"ssid='.*guest.*'\" | cut -d. -f2); do
      uci set wireless.\$i.key='$WIFI_GUEST'
    done"
    fi

    if [ -n "$WIFI_IOT" ]; then
      echo "  - Setting IoT network key..."
      UCI_COMMANDS="$UCI_COMMANDS
    for i in \$(uci show wireless | grep -i \"ssid='.*iot.*'\" | cut -d. -f2); do
      uci set wireless.\$i.key='$WIFI_IOT'
    done"
    fi

    if [ -z "$UCI_COMMANDS" ]; then
      echo "No secrets to configure."
      exit 0
    fi

    # Apply configuration
    ${pkgs.openssh}/bin/ssh "root@$TARGET" "
    $UCI_COMMANDS
    uci commit wireless
    wifi reload
    "

    echo "Secrets configured successfully."
  '';

  # Script to wait for device to come back online
  waitForDeviceScript = pkgs.writeShellScript "wait-for-device" ''
    TARGET="$1"
    MAX_WAIT="''${2:-180}"

    echo "Waiting for $TARGET to come back online (max ''${MAX_WAIT}s)..."

    elapsed=0
    while [ $elapsed -lt $MAX_WAIT ]; do
      if ${pkgs.openssh}/bin/ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$TARGET" "echo ok" >/dev/null 2>&1; then
        echo "Device is online."
        exit 0
      fi
      sleep 5
      elapsed=$((elapsed + 5))
      echo "  Still waiting... (''${elapsed}s)"
    done

    echo "Timeout waiting for device."
    exit 1
  '';

in {
  # Deploy an OpenWrt image to a device via sysupgrade
  openwrt-deploy = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-deploy" ''
        set -euo pipefail

        if [ $# -lt 2 ]; then
          echo "Usage: nix run .#openwrt-deploy -- <device-name> <device-ip> [--force] [--skip-secrets]"
          echo ""
          echo "Deploys an OpenWrt sysupgrade image to the specified device."
          echo ""
          echo "Arguments:"
          echo "  device-name    Name of the device (as defined in hosts/openwrt/)"
          echo "  device-ip      IP address or hostname of the device"
          echo "  --force        Skip confirmation prompt"
          echo "  --skip-secrets Skip secrets configuration after flash"
          echo ""
          echo "Example:"
          echo "  nix run .#openwrt-deploy -- bobcat 10.0.10.10"
          exit 1
        fi

        DEVICE="$1"
        TARGET="$2"
        shift 2

        FORCE=""
        SKIP_SECRETS=""
        for arg in "$@"; do
          case "$arg" in
            --force) FORCE="1" ;;
            --skip-secrets) SKIP_SECRETS="1" ;;
          esac
        done

        # Find repo root
        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -z "$REPO_ROOT" ]; then
          echo "Warning: Could not find repository root. Secrets will not be configured."
          SKIP_SECRETS="1"
        fi

        # Build the image
        echo "Building image for $DEVICE..."
        IMAGE_PATH=$(nix build --no-link --print-out-paths ".#openwrtImages.$DEVICE" 2>/dev/null)

        if [ -z "$IMAGE_PATH" ]; then
          echo "Error: Failed to build image for $DEVICE"
          echo "Make sure the device is defined in hosts/openwrt/default.nix"
          exit 1
        fi

        # Find the sysupgrade image
        SYSUPGRADE=$(find "$IMAGE_PATH" -name "*-sysupgrade.bin" -o -name "*-sysupgrade.img.gz" | head -1)

        if [ -z "$SYSUPGRADE" ]; then
          echo "Error: No sysupgrade image found in $IMAGE_PATH"
          exit 1
        fi

        echo "Image: $SYSUPGRADE"
        echo "Target: $TARGET"
        echo ""

        if [ -z "$FORCE" ]; then
          read -p "Deploy to $TARGET? This will reboot the device. [y/N] " -n 1 -r
          echo
          if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
          fi
        fi

        echo "Uploading image..."
        ${pkgs.openssh}/bin/scp -O "$SYSUPGRADE" "root@$TARGET:/tmp/sysupgrade.bin"

        echo "Starting sysupgrade (device will reboot)..."
        ${pkgs.openssh}/bin/ssh "root@$TARGET" "sysupgrade -v /tmp/sysupgrade.bin" || true

        echo ""
        echo "Upgrade initiated. Device is rebooting."

        if [ -z "$SKIP_SECRETS" ]; then
          echo ""
          ${waitForDeviceScript} "$TARGET" 180

          echo ""
          ${configureSecretsScript} "$TARGET" "$REPO_ROOT"
        else
          echo "Skipping secrets configuration (--skip-secrets specified)."
          echo "Wait ~2-3 minutes, then verify connectivity."
        fi

        echo ""
        echo "Deployment complete."
      '';
    in "${script}";
  };

  # Configure secrets on an already-deployed device
  openwrt-configure-secrets = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-configure-secrets-wrapper" ''
        set -euo pipefail

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-configure-secrets -- <device-ip>"
          echo ""
          echo "Configures wifi/mesh secrets on an OpenWrt device."
          echo "Secrets are read from hosts/openwrt/secrets/wifi.yaml (sops-encrypted)."
          echo ""
          echo "To create the secrets file:"
          echo "  sops hosts/openwrt/secrets/wifi.yaml"
          echo ""
          echo "Expected format:"
          echo "  mesh_key: \"your-mesh-password\""
          echo "  wifi_keys:"
          echo "    main: \"main-network-password\""
          echo "    guest: \"guest-network-password\""
          echo "    iot: \"iot-network-password\""
          exit 1
        fi

        TARGET="$1"
        REPO_ROOT=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")

        ${configureSecretsScript} "$TARGET" "$REPO_ROOT"
      '';
    in "${script}";
  };

  # List available OpenWrt device profiles
  openwrt-profiles = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-profiles" ''
        echo "Fetching available OpenWrt profiles..."
        echo "This may take a moment on first run."
        echo ""
        nix run github:astro/nix-openwrt-imagebuilder -- list-profiles "$@"
      '';
    in "${script}";
  };

  # Show UCI configuration that would be applied
  openwrt-show-config = {
    type = "app";
    program = let
      script = pkgs.writeShellScript "openwrt-show-config" ''
        set -euo pipefail

        if [ $# -lt 1 ]; then
          echo "Usage: nix run .#openwrt-show-config -- <device-name>"
          echo ""
          echo "Shows the UCI configuration that would be applied to the device."
          exit 1
        fi

        DEVICE="$1"

        # Build and extract the uci-defaults script
        IMAGE_PATH=$(nix build --no-link --print-out-paths ".#openwrtImages.$DEVICE" 2>/dev/null)

        if [ -z "$IMAGE_PATH" ]; then
          echo "Error: Failed to build image for $DEVICE"
          exit 1
        fi

        # The config files are in the build output
        if [ -f "$IMAGE_PATH/files/etc/uci-defaults/99-nix-config" ]; then
          cat "$IMAGE_PATH/files/etc/uci-defaults/99-nix-config"
        else
          echo "Searching for config in image..."
          find "$IMAGE_PATH" -name "99-nix-config" -exec cat {} \; 2>/dev/null || \
            echo "Could not find UCI defaults script"
        fi
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
