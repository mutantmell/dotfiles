# Flake apps for managing the dotfiles infrastructure
#
# Network registry:
#   nix run .#netinfo                         # Show all hosts
#   nix run .#netinfo -- <hostname>            # Look up a specific host
#   nix run .#netinfo -- --generate-docs       # Generate docs/network-hosts.md
#
# OpenWrt management:
#   nix run .#openwrt-build -- <device>         # Build image
#   nix run .#openwrt-deploy -- <device> <ip>   # Build + deploy to device
#   nix run .#openwrt-show-config -- <device>   # Show UCI config
{ pkgs, openwrtDevices, openwrtDeviceFiles }:

let
  openwrt = import ./openwrt { inherit pkgs openwrtDevices openwrtDeviceFiles; };
in {
  # Network registry lookup
  netinfo = import ./netinfo.nix { inherit pkgs; };

  # OpenWrt device management
  inherit (openwrt)
    openwrt-build
    openwrt-deploy
    openwrt-configure-secrets
    openwrt-show-config
    openwrt-export-config
    openwrt-analyze-packages
    openwrt-analyze-local;
}
