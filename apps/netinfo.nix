# Network host registry lookup tool
#
# Usage:
#   nix run .#netinfo                        # Show all hosts
#   nix run .#netinfo -- <hostname>           # Look up a specific host
#   nix run .#netinfo -- --generate-docs      # Generate docs/network-hosts.md
{ pkgs }:

let
  script = pkgs.writeShellScript "netinfo" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo ".")"

    if [ $# -eq 0 ]; then
      nix eval "$FLAKE_ROOT#lib.common.data.network.summary" --raw
    elif [ "$1" = "--generate-docs" ]; then
      DOCS_PATH="$FLAKE_ROOT/docs/network-hosts.md"
      mkdir -p "$(dirname "$DOCS_PATH")"
      nix eval "$FLAKE_ROOT#lib.common.data.network.markdown" --raw > "$DOCS_PATH"
      echo "Generated $DOCS_PATH"
    else
      HOST="$1"
      echo "IPv4: $(nix eval "$FLAKE_ROOT#lib.common.data.network.hosts.$HOST.ipv4" --raw)"
      echo "IPv6: $(nix eval "$FLAKE_ROOT#lib.common.data.network.hosts.$HOST.ipv6" --raw 2>/dev/null || echo "(none)")"
      echo "Zone: $(nix eval "$FLAKE_ROOT#lib.common.data.network.hosts.$HOST.zoneName" --raw)"
    fi
  '';
in {
  type = "app";
  program = "${script}";
}
