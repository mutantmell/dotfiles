# Host domain registry lookup tool
#
# Usage:
#   nix run .#hostinfo                        # Show all hosts with their domains
#   nix run .#hostinfo -- <hostname>           # Look up a specific host's domains
#   nix run .#hostinfo -- --generate-docs      # Generate docs/host-domains.md
#   nix run .#hostinfo -- --hostsfile            # Emit /etc/hosts format
{pkgs}: let
  script = pkgs.writeShellScript "hostinfo" ''
    set -euo pipefail
    FLAKE_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo ".")"

    if [ $# -eq 0 ]; then
      nix eval "$FLAKE_ROOT#lib.common.data.network.hostinfoSummary" --raw
    elif [ "$1" = "--generate-docs" ]; then
      DOCS_PATH="$FLAKE_ROOT/docs/host-domains.md"
      mkdir -p "$(dirname "$DOCS_PATH")"
      nix eval "$FLAKE_ROOT#lib.common.data.network.hostinfoMarkdown" --raw > "$DOCS_PATH"
      echo "Generated $DOCS_PATH"
    elif [ "$1" = "--hostsfile" ]; then
      nix eval "$FLAKE_ROOT#lib.common.data.network.hostsFile" --raw
    else
      HOST="$1"
      echo "IPv4:    $(nix eval "$FLAKE_ROOT#lib.common.data.network.hosts.$HOST.ipv4" --raw)"
      echo "IPv6:    $(nix eval "$FLAKE_ROOT#lib.common.data.network.hosts.$HOST.ipv6" --raw 2>/dev/null || echo "(none)")"
      echo "Zone:    $(nix eval "$FLAKE_ROOT#lib.common.data.network.hosts.$HOST.zoneName" --raw)"
      echo "Domains: $(nix eval "$FLAKE_ROOT#lib.common.data.network.domainsForHost" --json --apply "f: f \"$HOST\"")"
    fi
  '';
in {
  type = "app";
  program = "${script}";
}
