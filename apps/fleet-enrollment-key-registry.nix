# Fleet enrollment public key registry management
#
# Usage:
#   nix run .#fleet-enrollment-key-registry -- --list
#   nix run .#fleet-enrollment-key-registry -- --backfill [--guests-dir <path>] <parent-host>
#   nix run .#fleet-enrollment-key-registry -- --register <hostname> --target <ssh-host>
#
# Manages keys.json:fleetEnrollmentKeys — PEM ed25519 public keys generated on
# first boot by fleet-enrollment-key.service at /var/lib/fleet-tls/enrollment.pub.
# Separate from ssh-key-registry: formats differ (PEM vs SSH wire format) and
# the JSON subtree is different (fleetEnrollmentKeys vs hostKeys).
{pkgs}: let
  script = pkgs.writeShellScript "fleet-enrollment-key-registry" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    KEYS_JSON="$FLAKE_ROOT/lib/common/data/keys.json"

    ALL_DOMAINS=$(nix eval "$FLAKE_ROOT#lib.common.data.network.allHostDomains" --json)
    ALL_ENROLLMENT_KEYS=$(${pkgs.jq}/bin/jq -r '.fleetEnrollmentKeys // {}' "$KEYS_JSON")

    update_enrollment_key_registry() {
      local name="$1"
      local pubkey_pem="$2"
      ${pkgs.jq}/bin/jq --arg name "$name" --arg key "$pubkey_pem" \
        '.fleetEnrollmentKeys[$name] = $key' "$KEYS_JSON" > "$KEYS_JSON.tmp" \
        && mv "$KEYS_JSON.tmp" "$KEYS_JSON"
    }

    list_hosts() {
      echo "Hosts and their fleet enrollment key registration status:"
      echo ""
      local all_hosts
      all_hosts=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r 'keys[]')
      for h in $all_hosts; do
        local domains has_key
        domains=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$h" '.[$h] | join(", ")')
        has_key=$(echo "$ALL_ENROLLMENT_KEYS" | ${pkgs.jq}/bin/jq -r --arg h "$h" 'if .[$h] then "pubkey" else "no-key" end')
        printf "  %-16s [%-6s] %s\n" "$h" "$has_key" "$domains"
      done
    }

    fetch_and_register() {
      local hostname="$1"
      local ssh_target="$2"
      local ENROLLMENT_PUB_PATH="/var/lib/fleet-tls/enrollment.pub"

      echo "  Fetching enrollment pubkey from $ssh_target:$ENROLLMENT_PUB_PATH..."
      local pubkey_pem
      pubkey_pem=$(ssh root@"$ssh_target" "cat '$ENROLLMENT_PUB_PATH' 2>/dev/null") || {
        echo "  WARNING: Could not fetch enrollment pubkey from $hostname ($ssh_target)"
        echo "  Is fleet-enrollment-key.service running? Check: systemctl status fleet-enrollment-key"
        return 1
      }
      if [ -z "$pubkey_pem" ]; then
        echo "  WARNING: Empty enrollment pubkey from $hostname"
        return 1
      fi
      update_enrollment_key_registry "$hostname" "$pubkey_pem"
      echo "  Registered: $hostname"
    }

    case "''${1:-}" in
      --list)
        list_hosts
        ;;
      --register)
        shift
        if [ -z "''${1:-}" ] || [[ "$1" == --* ]]; then
          echo "Usage: nix run .#fleet-enrollment-key-registry -- --register <hostname> --target <ssh-host>"
          exit 1
        fi
        REG_HOST="$1"
        shift
        SSH_TARGET=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --target) SSH_TARGET="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
          esac
        done
        if [ -z "$SSH_TARGET" ]; then
          SSH_TARGET="${REG_HOST}.internal"
        fi
        fetch_and_register "$REG_HOST" "$SSH_TARGET"
        echo ""
        echo "Done. Next: nix run .#fleet-x5c-cert-sign -- --sign $REG_HOST && git commit"
        ;;
      --backfill)
        shift
        GUESTS_DIR="/persist/guests"
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --guests-dir) GUESTS_DIR="$2"; shift 2 ;;
            *) break ;;
          esac
        done

        PARENT_HOST="''${1:-}"
        if [ -z "$PARENT_HOST" ]; then
          echo "Usage: nix run .#fleet-enrollment-key-registry -- --backfill [--guests-dir <path>] <parent-host>"
          echo ""
          echo "Fetches fleet enrollment pubkeys via SSH and registers them in keys.json."
          echo "  - Parent host key: from /var/lib/fleet-tls/enrollment.pub"
          echo "  - Guest keys: from <guests-dir>/<guest>/state/var/lib/fleet-tls/enrollment.pub"
          exit 1
        fi

        SSH_TARGET="$PARENT_HOST.internal"
        echo "Backfilling fleet enrollment keys from $PARENT_HOST..."

        parent_in_registry=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$PARENT_HOST" 'has($h)')
        if [ "$parent_in_registry" = "true" ]; then
          fetch_and_register "$PARENT_HOST" "$SSH_TARGET" || true
        fi

        echo "  Discovering guests from flake structure..."
        guest_names=()
        for guest_type in microvm/guests incus/guests; do
          guest_base="$FLAKE_ROOT/hosts/$PARENT_HOST/$guest_type"
          if [ -d "$guest_base" ]; then
            for guest_path in "$guest_base"/*/; do
              [ -d "$guest_path" ] || continue
              guest="$(basename "$guest_path")"
              in_registry=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$guest" 'has($h)')
              if [ "$in_registry" = "true" ]; then
                guest_names+=("$guest")
              fi
            done
          fi
        done

        if [ ''${#guest_names[@]} -gt 0 ]; then
          echo "  Fetching enrollment keys for guests: ''${guest_names[*]}"
          for guest in "''${guest_names[@]}"; do
            guest_pub_path="$GUESTS_DIR/$guest/state/var/lib/fleet-tls/enrollment.pub"
            pubkey_pem=$(ssh root@"$SSH_TARGET" "cat '$guest_pub_path' 2>/dev/null") || {
              echo "  $guest: no enrollment key at $guest_pub_path, skipping"
              continue
            }
            if [ -n "$pubkey_pem" ]; then
              update_enrollment_key_registry "$guest" "$pubkey_pem"
              echo "  Registered: $guest"
            fi
          done
        fi

        echo ""
        echo "Done. Next steps for any newly registered hosts:"
        echo "  nix run .#fleet-x5c-cert-sign -- --sign <hostname>"
        echo "  git commit -m 'fleet: register enrollment keys and sign certs'"
        ;;
      "")
        echo "Usage:"
        echo "  nix run .#fleet-enrollment-key-registry -- --list"
        echo "  nix run .#fleet-enrollment-key-registry -- --register <hostname> [--target <ssh-host>]"
        echo "  nix run .#fleet-enrollment-key-registry -- --backfill [--guests-dir <path>] <parent-host>"
        ;;
      *)
        echo "Unknown option: $1"
        echo ""
        echo "Usage:"
        echo "  nix run .#fleet-enrollment-key-registry -- --list"
        echo "  nix run .#fleet-enrollment-key-registry -- --register <hostname> [--target <ssh-host>]"
        echo "  nix run .#fleet-enrollment-key-registry -- --backfill [--guests-dir <path>] <parent-host>"
        exit 1
        ;;
    esac
  '';
in {
  type = "app";
  program = "${script}";
}
