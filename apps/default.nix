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
  openwrtVmConfigurations,
}: let
  openwrt = import ./openwrt {inherit pkgs openwrtDevices openwrtConfigurations openwrtVmConfigurations;};
in {
  # Network registry lookup
  netinfo = import ./netinfo.nix {inherit pkgs;};

  # Host domain registry lookup
  hostinfo = import ./hostinfo.nix {inherit pkgs;};

  # SSH CA management
  ssh-ca-bootstrap = import ./ssh-ca-bootstrap.nix {inherit pkgs;};
  ssh-key-registry = import ./ssh-key-registry.nix {inherit pkgs;};
  ssh-host-cert-sign = import ./ssh-host-cert-sign.nix {inherit pkgs;};

  # Fleet X5C enrollment cert management
  fleet-enrollment-key-registry = import ./fleet-enrollment-key-registry.nix {inherit pkgs;};
  fleet-x5c-cert-sign = import ./fleet-x5c-cert-sign.nix {inherit pkgs;};

  # OpenWrt device management
  inherit
    (openwrt)
    openwrt-build
    openwrt-deploy
    openwrt-run
    openwrt-vm-smoke
    openwrt-deployer-vm
    openwrt-native-image-check
    openwrt-update-pins
    ;
}
