# One-time SSH CA key generation
#
# Usage:
#   nix run .#ssh-ca-bootstrap
#   nix run .#ssh-ca-bootstrap -- --force   # overwrite existing keys
#
# Generates SSH CA key pairs, writes public keys to lib/common/data/pki/,
# and prints sops commands to encrypt private keys into basel's secrets.
{pkgs}: let
  script = pkgs.writeShellScript "ssh-ca-bootstrap" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    PKI_DIR="$FLAKE_ROOT/lib/common/data/pki"
    SOPS_SECRETS="$FLAKE_ROOT/hosts/calvard/microvm/guests/basel/secrets/secrets.yaml"

    # Guard: don't overwrite existing keys unless --force
    if [ -f "$PKI_DIR/ssh_user_ca.pub" ] && [ "''${1:-}" != "--force" ]; then
      echo "SSH CA public keys already exist in $PKI_DIR."
      echo "Use --force to regenerate (invalidates all existing host/user certs)."
      exit 1
    fi

    KEYS_DIR="$FLAKE_ROOT/.keys"
    mkdir -p "$KEYS_DIR"

    # Generate key pairs in .keys directory
    ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$KEYS_DIR/ssh_user_ca_key" -C "ssh-user-ca@mutantmell.net" -N ""
    ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$KEYS_DIR/ssh_host_ca_key" -C "ssh-host-ca@mutantmell.net" -N ""

    # Write public keys to pki directory
    mkdir -p "$PKI_DIR"
    cp "$KEYS_DIR/ssh_user_ca_key.pub" "$PKI_DIR/ssh_user_ca.pub"
    cp "$KEYS_DIR/ssh_host_ca_key.pub" "$PKI_DIR/ssh_host_ca.pub"

    echo ""
    echo "SSH CA bootstrapped:"
    echo "  Public keys written to:"
    echo "    $PKI_DIR/ssh_user_ca.pub"
    echo "    $PKI_DIR/ssh_host_ca.pub"
    echo "  Private keys saved to:"
    echo "    $KEYS_DIR/ssh_user_ca_key"
    echo "    $KEYS_DIR/ssh_host_ca_key"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Encrypt private keys into basel's sops secrets:"
    echo "     sops keys: '[\"ssh_user_ca_key\"]' and '[\"ssh_host_ca_key\"]'"
    echo "     sops file: $SOPS_SECRETS"
    echo "     private key files: $KEYS_DIR/ssh_user_ca_key, $KEYS_DIR/ssh_host_ca_key"
    echo ""
    echo "  2. Commit the public keys:"
    echo "     git add lib/common/data/pki/ssh_user_ca.pub lib/common/data/pki/ssh_host_ca.pub"
  '';
in {
  type = "app";
  program = "${script}";
}
