# SSH host public key registry management
#
# Usage:
#   nix run .#ssh-key-registry -- --list
#   nix run .#ssh-key-registry -- --backfill [--guests-dir <path>] <parent-host>
{pkgs}: let
  script = pkgs.writeShellScript "ssh-key-registry" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    KEYS_JSON="$FLAKE_ROOT/lib/common/data/keys.json"

    # Fetch all host domains in one nix eval (avoid per-host eval overhead)
    ALL_DOMAINS=$(nix eval "$FLAKE_ROOT#lib.common.data.network.allHostDomains" --json)
    # Fetch host public keys from registry
    ALL_HOST_KEYS=$(nix eval "$FLAKE_ROOT#lib.common.data.keys.hostKeys" --json 2>/dev/null || echo "{}")

    # Update keys.json with a host public key
    update_host_key_registry() {
      local name="$1"
      local pubkey="$2"
      ${pkgs.jq}/bin/jq --arg name "$name" --arg key "$pubkey" \
        '.hostKeys[$name] = $key' "$KEYS_JSON" > "$KEYS_JSON.tmp" \
        && mv "$KEYS_JSON.tmp" "$KEYS_JSON"
    }

    list_hosts() {
      echo "Hosts and their SSH host key registration status:"
      echo ""
      local all_hosts
      all_hosts=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r 'keys[]')
      for h in $all_hosts; do
        local domains has_key
        domains=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$h" '.[$h] | join(", ")')
        has_key=$(echo "$ALL_HOST_KEYS" | ${pkgs.jq}/bin/jq -r --arg h "$h" 'if .[$h] then "pubkey" else "no-key" end')
        printf "  %-16s [%-6s] %s\n" "$h" "$has_key" "$domains"
      done
    }

    case "''${1:-}" in
      --list)
        list_hosts
        ;;
      --backfill)
        shift
        GUESTS_DIR="/persist/guests"
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --guests-dir)
              GUESTS_DIR="$2"
              shift 2
              ;;
            *)
              break
              ;;
          esac
        done

        PARENT_HOST="''${1:-}"
        if [ -z "$PARENT_HOST" ]; then
          echo "Usage: nix run .#ssh-key-registry -- --backfill [--guests-dir <path>] <parent-host>"
          echo ""
          echo "Fetches host public keys via SSH and registers them in keys.json."
          echo "  - Parent host key: from /etc/ssh/ssh_host_ed25519_key.pub"
          echo "  - Guest keys: from <guests-dir>/<guest>/static/etc/ssh/ssh_host_ed25519_key.pub"
          echo ""
          echo "Only guests that exist in the network registry are included."
          echo ""
          echo "Options:"
          echo "  --guests-dir <path>  Guest directory on the parent host (default: /persist/guests)"
          echo ""
          echo "Examples:"
          echo "  nix run .#ssh-key-registry -- --backfill calvard"
          echo "  nix run .#ssh-key-registry -- --backfill --guests-dir /data/guests remiferia"
          exit 1
        fi

        echo "Backfilling host keys from $PARENT_HOST..."

        SSH_TARGET="$PARENT_HOST.internal"

        # Fetch the parent host's own public key (only if it's in the network registry)
        parent_in_registry=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$PARENT_HOST" 'has($h)')
        if [ "$parent_in_registry" = "true" ]; then
          echo "  Fetching host key from $SSH_TARGET:/etc/ssh/ssh_host_ed25519_key.pub..."
          parent_pubkey=$(ssh root@"$SSH_TARGET" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null) || {
            echo "  WARNING: Could not fetch host key from $PARENT_HOST"
            parent_pubkey=""
          }
          if [ -n "$parent_pubkey" ]; then
            update_host_key_registry "$PARENT_HOST" "$parent_pubkey"
            echo "  Registered: $PARENT_HOST"
          fi
        else
          echo "  WARNING: $PARENT_HOST not found in network registry, skipping parent key"
        fi

        # Discover guests from local repo structure (microvm + incus)
        echo "  Discovering guests from flake structure..."
        guest_names=()
        for guest_type in microvm/guests incus/guests; do
          guest_base="$FLAKE_ROOT/hosts/$PARENT_HOST/$guest_type"
          if [ -d "$guest_base" ]; then
            for guest_path in "$guest_base"/*/; do
              [ -d "$guest_path" ] || continue
              guest="$(basename "$guest_path")"
              # Only include guests that exist in the network registry
              in_registry=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$guest" 'has($h)')
              if [ "$in_registry" = "true" ]; then
                guest_names+=("$guest")
              else
                echo "  $guest: not in network registry, skipping"
              fi
            done
          fi
        done

        if [ ''${#guest_names[@]} -gt 0 ]; then
          echo "  Fetching keys for guests: ''${guest_names[*]}"
          for guest in "''${guest_names[@]}"; do
            guest_key_path="$GUESTS_DIR/$guest/static/etc/ssh/ssh_host_ed25519_key.pub"
            guest_pubkey=$(ssh root@"$SSH_TARGET" "cat '$guest_key_path' 2>/dev/null") || {
              echo "  $guest: no key at $guest_key_path, skipping"
              continue
            }
            if [ -n "$guest_pubkey" ]; then
              update_host_key_registry "$guest" "$guest_pubkey"
              echo "  Registered: $guest"
            fi
          done
        else
          echo "  No registered guests found for $PARENT_HOST"
        fi

        echo ""
        echo "Done. Commit keys.json to persist."
        ;;
      "")
        echo "Usage:"
        echo "  nix run .#ssh-key-registry -- --list"
        echo "  nix run .#ssh-key-registry -- --backfill [--guests-dir <path>] <parent-host>"
        ;;
      *)
        echo "Unknown option: $1"
        echo ""
        echo "Usage:"
        echo "  nix run .#ssh-key-registry -- --list"
        echo "  nix run .#ssh-key-registry -- --backfill [--guests-dir <path>] <parent-host>"
        exit 1
        ;;
    esac
  '';
in {
  type = "app";
  program = "${script}";
}
