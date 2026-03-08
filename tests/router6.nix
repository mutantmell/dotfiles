# Permanent router6 tests
#
# These are stable tests for the router6 module that should always pass.
# Run all: ./scripts/run-checks.sh
# Run one: nix build .#checks.x86_64-linux.<name>
{
  pkgs,
  lib,
}: {
  # NixOS VM integration tests
  router6-ipv6 = import ./modules/router6-ipv6.nix {inherit pkgs lib;};
  router6-firewall = import ./modules/router6-firewall.nix {inherit pkgs lib;};
  router6-firewall-zones = import ./modules/router6-firewall-zones.nix {inherit pkgs lib;};
  router6-bond-bridge = import ./modules/router6-bond-bridge.nix {inherit pkgs lib;};
  router6-device-vlans = import ./modules/router6-device-vlans.nix {inherit pkgs lib;};
  router6-bridge-vlan-ordering = import ./modules/router6-bridge-vlan-ordering.nix {inherit pkgs lib;};
  router6-wan-dhcp = import ./modules/router6-wan-dhcp.nix {inherit pkgs lib;};
  router6-wan-ipv6-pd = import ./modules/router6-wan-ipv6-pd.nix {inherit pkgs lib;};
  router6-dhcpv6 = import ./modules/router6-dhcpv6.nix {inherit pkgs lib;};
  egress-filter = import ./modules/egress-filter.nix {inherit pkgs lib;};

  # Pure Nix evaluation tests
  nftables-dsl = import ./lib/nftables.nix {inherit pkgs lib;};
  router6-zone-system = import ./lib/router6-zone-system.nix {inherit pkgs lib;};
  router6-firewall-properties = import ./lib/router6-firewall-properties.nix {inherit pkgs lib;};
  router6-dhcp-config = import ./lib/router6-dhcp-config.nix {inherit pkgs lib;};
  network-helpers = import ./lib/network-helpers.nix {inherit pkgs lib;};
  openwrt-config = import ./lib/openwrt-config.nix {inherit pkgs lib;};
}
