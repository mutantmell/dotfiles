# SSH host certificate signing tool
#
# Usage:
#   nix run .#ssh-cert-sign -- <hostname> <pubkey-path>
#   nix run .#ssh-cert-sign -- --all
#   nix run .#ssh-cert-sign -- --list
#   nix run .#ssh-cert-sign -- --backfill [--guests-dir <path>] <parent-host>
{pkgs}: let
  script = pkgs.writeShellScript "ssh-cert-sign" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    JSON_FILE="$FLAKE_ROOT/lib/common/data/ssh-ca.json"
    KEYS_JSON="$FLAKE_ROOT/lib/common/data/keys.json"
    CA_KEY="$FLAKE_ROOT/.keys/ssh_host_ca_key"

    # Fetch all host domains in one nix eval (avoid per-host eval overhead)
    ALL_DOMAINS=$(nix eval "$FLAKE_ROOT#lib.common.data.network.allHostDomains" --json)
    # Fetch host public keys from registry
    ALL_HOST_KEYS=$(nix eval "$FLAKE_ROOT#lib.common.data.keys.hostKeys" --json 2>/dev/null || echo "{}")

    require_ca() {
      if [ ! -f "$CA_KEY" ]; then
        echo "Host CA key not found at $CA_KEY"
        echo "Run 'nix run .#ssh-ca-bootstrap' first."
        exit 1
      fi

      if [ ! -f "$JSON_FILE" ]; then
        echo "SSH CA data not found at $JSON_FILE"
        echo "Run 'nix run .#ssh-ca-bootstrap' first."
        exit 1
      fi
    }

    # Shared signing logic: sign_host_inner <hostname> <pubkey-file>
    sign_host_inner() {
      local hostname="$1"
      local pubkey_path="$2"

      # Extract domains for this host from the pre-fetched data
      local domains
      domains=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$hostname" '.[$h][]')

      if [ -z "$domains" ]; then
        echo "No domains found for host: $hostname"
        return 1
      fi

      # Build principal flags from domains
      local principal_args=()
      for domain in $domains; do
        principal_args+=(--principal "$domain")
      done

      # Sign to temp file, then read the cert string
      local work_dir
      work_dir=$(mktemp -d)

      # Copy pubkey to temp location (step requires it)
      cp "$pubkey_path" "$work_dir/key.pub"

      ${pkgs.step-cli}/bin/step ssh certificate "$hostname.internal" "$work_dir/key-cert.pub" \
        --host --sign \
        --ca-key "$CA_KEY" \
        "''${principal_args[@]}" \
        --not-after 87600h

      # Read the certificate and update JSON
      local cert_content
      cert_content=$(cat "$work_dir/key-cert.pub")

      rm -rf "$work_dir"

      ${pkgs.jq}/bin/jq --arg host "$hostname" --arg cert "$cert_content" \
        '.hostCerts[$host] = $cert' "$JSON_FILE" > "$JSON_FILE.tmp" \
        && mv "$JSON_FILE.tmp" "$JSON_FILE"

      echo "Signed: $hostname"
      echo "  Principals: $(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$hostname" '.[$h] | join(", ")')"
      echo "  Updated: $JSON_FILE"
    }

    # Sign from a file path (single-host mode)
    sign_host_from_file() {
      local hostname="$1"
      local pubkey_path="$2"

      if [ ! -f "$pubkey_path" ]; then
        echo "Public key not found: $pubkey_path"
        return 1
      fi

      sign_host_inner "$hostname" "$pubkey_path"
    }

    # Sign from a pubkey string (registry mode)
    sign_host_from_string() {
      local hostname="$1"
      local pubkey="$2"

      local tmp_file
      tmp_file=$(mktemp)
      echo "$pubkey" > "$tmp_file"
      sign_host_inner "$hostname" "$tmp_file"
      rm -f "$tmp_file"
    }

    # Update keys.json with a host public key
    update_host_key_registry() {
      local name="$1"
      local pubkey="$2"
      ${pkgs.jq}/bin/jq --arg name "$name" --arg key "$pubkey" \
        '.hostKeys[$name] = $key' "$KEYS_JSON" > "$KEYS_JSON.tmp" \
        && mv "$KEYS_JSON.tmp" "$KEYS_JSON"
    }

    list_hosts() {
      echo "Hosts and their SSH certificate principals:"
      echo ""
      local all_hosts
      all_hosts=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r 'keys[]')
      for h in $all_hosts; do
        local domains signed has_key
        domains=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$h" '.[$h] | join(", ")')
        signed=$(${pkgs.jq}/bin/jq -r --arg h "$h" 'if .hostCerts[$h] then "signed" else "unsigned" end' "$JSON_FILE")
        has_key=$(echo "$ALL_HOST_KEYS" | ${pkgs.jq}/bin/jq -r --arg h "$h" 'if .[$h] then "pubkey" else "no-key" end')
        printf "  %-16s [%-8s] [%-6s] %s\n" "$h" "$signed" "$has_key" "$domains"
      done
    }

    case "''${1:-}" in
      --list)
        require_ca
        list_hosts
        ;;
      --all)
        require_ca
        echo "Signing all hosts with registered public keys..."
        echo ""
        failed=()
        all_hosts=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r 'keys[]')
        for h in $all_hosts; do
          pubkey=$(echo "$ALL_HOST_KEYS" | ${pkgs.jq}/bin/jq -r --arg h "$h" '.[$h] // empty')
          if [ -z "$pubkey" ]; then
            echo "  $h: no public key in registry, skipping"
            continue
          fi
          if ! sign_host_from_string "$h" "$pubkey"; then
            echo "  ERROR: failed to sign $h"
            failed+=("$h")
          fi
          echo ""
        done
        if [ ''${#failed[@]} -gt 0 ]; then
          echo "Failed to sign: ''${failed[*]}"
          exit 1
        fi
        echo "Done. Hosts without registered keys were skipped."
        echo "Use '--backfill' to register keys from live hosts."
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
          echo "Usage: nix run .#ssh-cert-sign -- --backfill [--guests-dir <path>] <parent-host>"
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
          echo "  nix run .#ssh-cert-sign -- --backfill calvard"
          echo "  nix run .#ssh-cert-sign -- --backfill --guests-dir /data/guests remiferia"
          exit 1
        fi

        echo "Backfilling host keys from $PARENT_HOST..."

        # Fetch the parent host's own public key (only if it's in the network registry)
        parent_in_registry=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$PARENT_HOST" 'has($h)')
        if [ "$parent_in_registry" = "true" ]; then
          echo "  Fetching host key from $PARENT_HOST:/etc/ssh/ssh_host_ed25519_key.pub..."
          parent_pubkey=$(ssh "$PARENT_HOST" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null) || {
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
            guest_pubkey=$(ssh "$PARENT_HOST" "cat '$guest_key_path' 2>/dev/null") || {
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
        echo "  nix run .#ssh-cert-sign -- <hostname> <pubkey-path>"
        echo "  nix run .#ssh-cert-sign -- --all"
        echo "  nix run .#ssh-cert-sign -- --list"
        echo "  nix run .#ssh-cert-sign -- --backfill [--guests-dir <path>] <parent-host>"
        ;;
      *)
        require_ca
        if [ $# -lt 2 ]; then
          echo "Usage: nix run .#ssh-cert-sign -- <hostname> <pubkey-path>"
          exit 1
        fi
        sign_host_from_file "$1" "$2"
        ;;
    esac
  '';
in {
  type = "app";
  program = "${script}";
}
