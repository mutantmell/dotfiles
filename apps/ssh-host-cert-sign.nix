# SSH host certificate signing via ssh-keygen
#
# Usage:
#   nix run .#ssh-host-cert-sign -- --list
#   nix run .#ssh-host-cert-sign -- --sign-all [--ca-key <path>]
#   nix run .#ssh-host-cert-sign -- --sign <hostname> [--ca-key <path>]
#
# Signs host public keys from keys.json using the SSH host CA private key
# and writes certificates to lib/common/data/host-certs/.
{pkgs}: let
  script = pkgs.writeShellScript "ssh-host-cert-sign" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    KEYS_JSON="$FLAKE_ROOT/lib/common/data/keys.json"
    CERTS_DIR="$FLAKE_ROOT/lib/common/data/host-certs"
    SSH_HOST_CA="$FLAKE_ROOT/lib/common/data/pki/ssh_host_ca.pub"

    TMPDIR_KEYS=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_KEYS"' EXIT

    # Empty means: load from passage at signing time
    CA_KEY=""

    load_ca_key_from_passage() {
      local tmp_key="$TMPDIR_KEYS/ssh_host_ca_key"
      if passage show "pki/ssh_host_ca_key" > "$tmp_key" 2>/dev/null; then
        chmod 600 "$tmp_key"
        CA_KEY="$tmp_key"
      else
        echo "CA key not found in passage (pki/ssh_host_ca_key)"
        echo "  Store it with: passage insert -m -f \"pki/ssh_host_ca_key\""
        echo "  Or provide explicitly: --ca-key <path>"
        exit 1
      fi
    }

    ensure_ca_key() {
      if [ -z "$CA_KEY" ]; then
        load_ca_key_from_passage
      elif [ ! -f "$CA_KEY" ]; then
        echo "CA key not found: $CA_KEY"
        exit 1
      fi
    }

    # Fetch all host domains in one nix eval
    ALL_DOMAINS=$(nix eval "$FLAKE_ROOT#lib.common.data.network.allHostDomains" --json)
    # Fetch host public keys from registry
    ALL_HOST_KEYS=$(${pkgs.jq}/bin/jq -r '.hostKeys' "$KEYS_JSON")

    sign_host() {
      local hostname="$1"
      local pubkey
      pubkey=$(echo "$ALL_HOST_KEYS" | ${pkgs.jq}/bin/jq -r --arg h "$hostname" '.[$h] // empty')
      if [ -z "$pubkey" ]; then
        echo "  $hostname: no host key registered, skipping"
        return 1
      fi

      local principals
      principals=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$hostname" '.[$h] // empty | join(",")')
      if [ -z "$principals" ]; then
        echo "  $hostname: not in network registry, skipping"
        return 1
      fi

      # Write pubkey to temp file (ssh-keygen requires a file)
      local tmpdir
      tmpdir=$(mktemp -d)
      trap "rm -rf $tmpdir" RETURN
      echo "$pubkey" > "$tmpdir/$hostname.pub"

      echo "  $hostname: signing..."
      if ! ${pkgs.openssh}/bin/ssh-keygen \
        -s "$CA_KEY" \
        -I "$hostname" \
        -h \
        -n "$principals" \
        -V "+731d" \
        -z "$(date +%s)" \
        "$tmpdir/$hostname.pub"; then
        echo "  $hostname: ERROR: ssh-keygen failed"
        return 1
      fi

      # Move certificate to final location
      mkdir -p "$CERTS_DIR"
      mv "$tmpdir/$hostname-cert.pub" "$CERTS_DIR/$hostname-cert.pub"
      echo "  $hostname: signed -> $CERTS_DIR/$hostname-cert.pub"

      # Show cert details
      ${pkgs.openssh}/bin/ssh-keygen -L -f "$CERTS_DIR/$hostname-cert.pub" 2>/dev/null | head -6 | sed 's/^/    /'
    }

    list_hosts() {
      echo "Hosts and their SSH host certificate status:"
      echo ""
      local all_hosts
      all_hosts=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r 'keys[]')
      for h in $all_hosts; do
        local domains has_key has_cert cert_expiry
        domains=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$h" '.[$h] | join(", ")')
        has_key=$(echo "$ALL_HOST_KEYS" | ${pkgs.jq}/bin/jq -r --arg h "$h" 'if .[$h] then "key" else "no-key" end')
        cert_file="$CERTS_DIR/$h-cert.pub"
        if [ -f "$cert_file" ]; then
          cert_expiry=$(${pkgs.openssh}/bin/ssh-keygen -L -f "$cert_file" 2>/dev/null | grep "Valid:" | sed 's/.*to //' || echo "unknown")
          has_cert="cert"
        else
          cert_expiry="-"
          has_cert="no-cert"
        fi
        printf "  %-16s [%-6s] [%-7s] expires: %-20s %s\n" "$h" "$has_key" "$has_cert" "$cert_expiry" "$domains"
      done
    }

    print_client_trust() {
      if [ -f "$SSH_HOST_CA" ]; then
        echo ""
        echo "Add this line to ~/.ssh/known_hosts to trust host certificates:"
        echo ""
        local ca_key
        ca_key=$(cat "$SSH_HOST_CA")
        echo "  @cert-authority *.internal,*.internal.mutantmell.net,*.mutantmell.net $ca_key"
        echo ""
      fi
    }

    # Parse options and subcommand
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ca-key)
          CA_KEY="$2"
          shift 2
          ;;
        --list)
          list_hosts
          exit 0
          ;;
        --sign-all)
          shift
          # Parse remaining options
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --ca-key) CA_KEY="$2"; shift 2 ;;
              *) echo "Unknown option: $1"; exit 1 ;;
            esac
          done
          ensure_ca_key
          echo "Signing all hosts with registered keys..."
          echo ""
          succeeded=0
          failed=0
          all_hosts=$(echo "$ALL_HOST_KEYS" | ${pkgs.jq}/bin/jq -r 'keys[]')
          for h in $all_hosts; do
            if sign_host "$h"; then
              succeeded=$((succeeded + 1))
            else
              failed=$((failed + 1))
            fi
          done
          echo ""
          echo "Done: $succeeded succeeded, $failed failed"
          print_client_trust
          exit 0
          ;;
        --sign)
          shift
          if [ -z "''${1:-}" ] || [[ "$1" == --* ]]; then
            echo "Usage: nix run .#ssh-host-cert-sign -- --sign <hostname> [--ca-key <path>]"
            exit 1
          fi
          hostname="$1"
          shift
          # Parse remaining options
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --ca-key) CA_KEY="$2"; shift 2 ;;
              *) echo "Unknown option: $1"; exit 1 ;;
            esac
          done
          ensure_ca_key
          echo "Signing host: $hostname"
          sign_host "$hostname"
          print_client_trust
          exit 0
          ;;
        *)
          echo "Unknown option: $1"
          echo ""
          echo "Usage:"
          echo "  nix run .#ssh-host-cert-sign -- --list"
          echo "  nix run .#ssh-host-cert-sign -- --sign-all [--ca-key <path>]"
          echo "  nix run .#ssh-host-cert-sign -- --sign <hostname> [--ca-key <path>]"
          exit 1
          ;;
      esac
    done

    echo "Usage:"
    echo "  nix run .#ssh-host-cert-sign -- --list"
    echo "  nix run .#ssh-host-cert-sign -- --sign-all [--ca-key <path>]"
    echo "  nix run .#ssh-host-cert-sign -- --sign <hostname> [--ca-key <path>]"
  '';
in {
  type = "app";
  program = "${script}";
}
