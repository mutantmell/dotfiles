# Flake apps for managing the dotfiles infrastructure
#
# Network registry:
#   nix run .#netinfo                         # Show all hosts
#   nix run .#netinfo -- <hostname>            # Look up a specific host
#   nix run .#netinfo -- --generate-docs       # Generate docs/network-hosts.md
#
# Host domain registry:
#   nix run .#hostinfo                        # Show all hosts with their domains
#   nix run .#hostinfo -- <hostname>           # Look up a specific host's domains
#   nix run .#hostinfo -- --generate-docs      # Generate docs/host-domains.md
#   nix run .#hostinfo -- --hostsfile          # Emit /etc/hosts format
#
# OpenWrt management:
#   nix run .#openwrt-build -- <device>         # Build image
#   nix run .#openwrt-deploy -- <device> <ip>   # Build + deploy to device
{
  pkgs,
  openwrtDevices,
  openwrtConfigurations,
}: let
  openwrt = import ./openwrt {inherit pkgs openwrtDevices openwrtConfigurations;};
in {
  # Network registry lookup
  netinfo = import ./netinfo.nix {inherit pkgs;};

  # Host domain registry lookup
  hostinfo = import ./hostinfo.nix {inherit pkgs;};

  # SSH CA management
  ssh-ca-bootstrap = import ./ssh-ca-bootstrap.nix {inherit pkgs;};
  ssh-cert-sign = import ./ssh-cert-sign.nix {inherit pkgs;};

  # OpenWrt device management
  inherit
    (openwrt)
    openwrt-build
    openwrt-deploy
    openwrt-run
    openwrt-export-config
    openwrt-analyze-packages
    openwrt-analyze-local
    ;
}
