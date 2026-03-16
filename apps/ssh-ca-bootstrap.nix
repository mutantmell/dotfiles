# One-time SSH CA key generation
#
# Usage:
#   nix run .#ssh-ca-bootstrap
#   nix run .#ssh-ca-bootstrap -- --force   # overwrite existing CA keys
#
# Future goals:
#   - Encrypt CA private keys as sops secrets on basel (the PKI host).
#     sops-nix decrypts to /run/secrets/ (tmpfs), so keys are only
#     materialized in memory. Once stored there, remove from .keys/.
#   - When step-ca is deployed on basel, it can use the sops-managed
#     keys directly for automated certificate issuance.
{pkgs}: let
  script = pkgs.writeShellScript "ssh-ca-bootstrap" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
    JSON_FILE="$FLAKE_ROOT/lib/common/data/ssh-ca.json"
    KEYS_DIR="$FLAKE_ROOT/.keys"

    # Guard: don't overwrite existing keys unless --force
    if [ -f "$JSON_FILE" ] && [ "''${1:-}" != "--force" ]; then
      echo "SSH CA data already exists at $JSON_FILE."
      echo "Use --force to regenerate (invalidates all existing host certs)."
      exit 1
    fi

    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT

    # Generate key pairs
    ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$WORK_DIR/ssh_user_ca_key" -C "ssh-user-ca@mutantmell.net" -N ""
    ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$WORK_DIR/ssh_host_ca_key" -C "ssh-host-ca@mutantmell.net" -N ""

    # Read public keys
    USER_CA_PUB=$(cat "$WORK_DIR/ssh_user_ca_key.pub")
    HOST_CA_PUB=$(cat "$WORK_DIR/ssh_host_ca_key.pub")

    # Create JSON file with CA public keys
    ${pkgs.jq}/bin/jq -n \
      --arg userCA "$USER_CA_PUB" \
      --arg hostCA "$HOST_CA_PUB" \
      '{ userCA: $userCA, hostCA: $hostCA, hostCerts: {} }' \
      > "$JSON_FILE"

    # Place private keys alongside age keys
    mkdir -p "$KEYS_DIR"
    cp "$WORK_DIR/ssh_user_ca_key" "$KEYS_DIR/"
    cp "$WORK_DIR/ssh_host_ca_key" "$KEYS_DIR/"
    chmod 600 "$KEYS_DIR/ssh_user_ca_key" "$KEYS_DIR/ssh_host_ca_key"

    echo ""
    echo "SSH CA bootstrapped:"
    echo "  Data:    $JSON_FILE"
    echo "  Private: $KEYS_DIR/ssh_user_ca_key"
    echo "  Private: $KEYS_DIR/ssh_host_ca_key"
    echo ""
    echo "Private keys live in .keys/ (gitignored). Keep a backup — these are"
    echo "the root of trust for SSH certificate auth. They are used locally by"
    echo "ssh-cert-sign and do not need to be deployed to any host."
    echo ""
    echo "Next steps:"
    echo "  1. Run: nix run .#ssh-cert-sign -- --all"
    echo "  2. Commit ssh-ca.json"
  '';
in {
  type = "app";
  program = "${script}";
}
