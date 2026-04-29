# Fleet X5C enrollment certificate signing via openssl
#
# Usage:
#   nix run .#fleet-x5c-cert-sign -- --list
#   nix run .#fleet-x5c-cert-sign -- --sign-all [--ca-key <path>]
#   nix run .#fleet-x5c-cert-sign -- --sign <hostname> [--ca-key <path>]
#
# Signs enrollment public keys from keys.json:fleetEnrollmentKeys using the
# offline X5C CA private key and writes certs to lib/common/data/fleet-x5c-certs/.
#
# Uses openssl x509 -force_pubkey (OpenSSL 3+) to sign a cert from a raw public
# key without requiring a CSR from the subject's private key.
{pkgs}: let
  script = pkgs.writeShellScript "fleet-x5c-cert-sign" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    KEYS_JSON="$FLAKE_ROOT/lib/common/data/keys.json"
    CERTS_DIR="$FLAKE_ROOT/lib/common/data/fleet-x5c-certs"
    CA_CRT="$FLAKE_ROOT/lib/common/data/pki/fleet_x5c_ca.crt"

    TMPDIR_KEYS=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_KEYS"' EXIT

    # Empty means: load from passage at signing time
    CA_KEY=""

    load_ca_key_from_passage() {
      local tmp_key="$TMPDIR_KEYS/fleet_x5c_ca_key"
      if passage show "pki/fleet_x5c_ca_key" > "$tmp_key" 2>/dev/null; then
        chmod 600 "$tmp_key"
        CA_KEY="$tmp_key"
      else
        echo "CA key not found in passage (pki/fleet_x5c_ca_key)"
        echo "  Store it with: passage insert -m -f \"pki/fleet_x5c_ca_key\""
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
    # Fetch fleet enrollment public keys from registry
    ALL_ENROLLMENT_KEYS=$(${pkgs.jq}/bin/jq -r '.fleetEnrollmentKeys // {}' "$KEYS_JSON")

    sign_host() {
      local hostname="$1"
      local pubkey_pem
      pubkey_pem=$(echo "$ALL_ENROLLMENT_KEYS" | ${pkgs.jq}/bin/jq -r --arg h "$hostname" '.[$h] // empty')
      if [ -z "$pubkey_pem" ]; then
        echo "  $hostname: no fleet enrollment key registered, skipping"
        return 1
      fi

      local domains_json
      domains_json=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$hostname" '.[$h] // empty')
      if [ -z "$domains_json" ] || [ "$domains_json" = "null" ]; then
        echo "  $hostname: not in network registry, skipping"
        return 1
      fi

      local tmpdir
      tmpdir=$(mktemp -d)
      trap "rm -rf $tmpdir" RETURN

      echo "$pubkey_pem" > "$tmpdir/$hostname.pub"

      # Assert: leaf cert Not After must be < CA cert Not After (X5C validity-ordering rule).
      local ca_end_epoch ca_end_sec leaf_end_sec
      ca_end_epoch=$(${pkgs.openssl}/bin/openssl x509 -enddate -noout -in "$CA_CRT" 2>/dev/null \
        | sed 's/notAfter=//')
      ca_end_sec=$(date -d "$ca_end_epoch" +%s 2>/dev/null \
        || date -jf "%b %e %H:%M:%S %Y %Z" "$ca_end_epoch" +%s 2>/dev/null)
      leaf_end_sec=$(( $(date +%s) + 1825 * 86400 ))
      if [ "$leaf_end_sec" -ge "$ca_end_sec" ]; then
        echo "  $hostname: ERROR: CA cert expires before the 5y leaf cert would. Rotate CA first."
        return 1
      fi

      # Build SAN string for openssl extensions config
      local san_items=() san
      while IFS= read -r san; do
        san_items+=("DNS:$san")
      done < <(echo "$domains_json" | ${pkgs.jq}/bin/jq -r '.[]')
      local san_str
      san_str=$(printf '%s,' "''${san_items[@]}" | sed 's/,$//')

      # Write openssl extensions config
      cat > "$tmpdir/ext.cnf" <<EOF
[v3_ext]
subjectAltName = ''${san_str}
keyUsage = critical,digitalSignature
extendedKeyUsage = clientAuth
basicConstraints = CA:FALSE
EOF

      # A throw-away keypair is needed only to produce a structurally valid CSR.
      # -force_pubkey replaces its public key with the enrollment key before signing,
      # so the dummy private key is never used for anything meaningful.
      ${pkgs.openssl}/bin/openssl genpkey -algorithm ED25519 \
        -out "$tmpdir/dummy.key" 2>/dev/null
      ${pkgs.openssl}/bin/openssl req -new \
        -key "$tmpdir/dummy.key" \
        -subj "/CN=''${hostname}.internal" \
        -out "$tmpdir/$hostname.csr" 2>/dev/null

      echo "  $hostname: signing..."
      if ! ${pkgs.openssl}/bin/openssl x509 -req \
          -in "$tmpdir/$hostname.csr" \
          -force_pubkey "$tmpdir/$hostname.pub" \
          -CA "$CA_CRT" \
          -CAkey "$CA_KEY" \
          -CAcreateserial \
          -days 1825 \
          -extfile "$tmpdir/ext.cnf" \
          -extensions v3_ext \
          -out "$CERTS_DIR/$hostname.crt" 2>/dev/null; then
        echo "  $hostname: ERROR: openssl signing failed"
        return 1
      fi

      echo "  $hostname: signed -> $CERTS_DIR/$hostname.crt"

      ${pkgs.openssl}/bin/openssl x509 -in "$CERTS_DIR/$hostname.crt" \
        -noout -subject -enddate -ext subjectAltName 2>/dev/null | sed 's/^/    /'
    }

    list_hosts() {
      echo "Hosts and their fleet X5C enrollment certificate status:"
      echo ""
      if [ ! -f "$CA_CRT" ]; then
        echo "  WARNING: CA cert not found at $CA_CRT"
        echo "  Generate with: step certificate create fleet-x5c-ca $CA_CRT <key> --profile root-ca"
        echo ""
      fi
      local all_hosts
      all_hosts=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r 'keys[]')
      for h in $all_hosts; do
        local domains has_key has_cert cert_expiry cert_file
        domains=$(echo "$ALL_DOMAINS" | ${pkgs.jq}/bin/jq -r --arg h "$h" '.[$h] | join(", ")')
        has_key=$(echo "$ALL_ENROLLMENT_KEYS" | ${pkgs.jq}/bin/jq -r --arg h "$h" 'if .[$h] then "key" else "no-key" end')
        cert_file="$CERTS_DIR/$h.crt"
        if [ -f "$cert_file" ]; then
          cert_expiry=$(${pkgs.openssl}/bin/openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null \
            | sed 's/notAfter=//' || echo "unknown")
          has_cert="cert"
        else
          cert_expiry="-"
          has_cert="no-cert"
        fi
        printf "  %-16s [%-6s] [%-7s] expires: %-30s %s\n" "$h" "$has_key" "$has_cert" "$cert_expiry" "$domains"
      done
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
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --ca-key) CA_KEY="$2"; shift 2 ;;
              *) echo "Unknown option: $1"; exit 1 ;;
            esac
          done
          if [ ! -f "$CA_CRT" ]; then
            echo "CA cert not found: $CA_CRT"
            echo "Generate the fleet X5C CA first (see plan for instructions)"
            exit 1
          fi
          ensure_ca_key
          echo "Signing all hosts with registered fleet enrollment keys..."
          echo ""
          mkdir -p "$CERTS_DIR"
          succeeded=0
          failed=0
          all_hosts=$(echo "$ALL_ENROLLMENT_KEYS" | ${pkgs.jq}/bin/jq -r 'keys[]')
          for h in $all_hosts; do
            if sign_host "$h"; then
              succeeded=$((succeeded + 1))
            else
              failed=$((failed + 1))
            fi
          done
          echo ""
          echo "Done: $succeeded succeeded, $failed failed"
          exit 0
          ;;
        --sign)
          shift
          if [ -z "''${1:-}" ] || [[ "$1" == --* ]]; then
            echo "Usage: nix run .#fleet-x5c-cert-sign -- --sign <hostname> [--ca-key <path>]"
            exit 1
          fi
          hostname="$1"
          shift
          while [[ $# -gt 0 ]]; do
            case "$1" in
              --ca-key) CA_KEY="$2"; shift 2 ;;
              *) echo "Unknown option: $1"; exit 1 ;;
            esac
          done
          if [ ! -f "$CA_CRT" ]; then
            echo "CA cert not found: $CA_CRT"
            echo "Generate the fleet X5C CA first (see plan for instructions)"
            exit 1
          fi
          ensure_ca_key
          mkdir -p "$CERTS_DIR"
          echo "Signing host: $hostname"
          sign_host "$hostname"
          exit 0
          ;;
        *)
          echo "Unknown option: $1"
          echo ""
          echo "Usage:"
          echo "  nix run .#fleet-x5c-cert-sign -- --list"
          echo "  nix run .#fleet-x5c-cert-sign -- --sign-all [--ca-key <path>]"
          echo "  nix run .#fleet-x5c-cert-sign -- --sign <hostname> [--ca-key <path>]"
          exit 1
          ;;
      esac
    done

    echo "Usage:"
    echo "  nix run .#fleet-x5c-cert-sign -- --list"
    echo "  nix run .#fleet-x5c-cert-sign -- --sign-all [--ca-key <path>]"
    echo "  nix run .#fleet-x5c-cert-sign -- --sign <hostname> [--ca-key <path>]"
  '';
in {
  type = "app";
  program = "${script}";
}
