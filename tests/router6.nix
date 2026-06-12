# Permanent router6 tests
#
# These are stable tests for the router6 module that should always pass.
# Run all: ./scripts/run-checks.sh
# Run one: nix build .#checks.x86_64-linux.<name>
{
  pkgs,
  lib,
}: let
  mkContainerTest = path:
    import path {
      inherit pkgs lib;
      useContainers = true;
    };
in {
  # NixOS VM integration tests
  router6-ipv6 = import ./modules/router6-ipv6.nix {inherit pkgs lib;};
  router6-ipv6-privacy = import ./modules/router6-ipv6-privacy.nix {inherit pkgs lib;};
  router6-firewall = import ./modules/router6-firewall.nix {inherit pkgs lib;};
  router6-firewall-zones = import ./modules/router6-firewall-zones.nix {inherit pkgs lib;};
  router6-bond-bridge = import ./modules/router6-bond-bridge.nix {inherit pkgs lib;};
  router6-device-vlans = import ./modules/router6-device-vlans.nix {inherit pkgs lib;};
  router6-bridge-vlan-ordering = import ./modules/router6-bridge-vlan-ordering.nix {inherit pkgs lib;};
  router6-wan-dhcp = import ./modules/router6-wan-dhcp.nix {inherit pkgs lib;};
  router6-wan-ipv6-pd = import ./modules/router6-wan-ipv6-pd.nix {inherit pkgs lib;};
  router6-dhcpv6 = import ./modules/router6-dhcpv6.nix {inherit pkgs lib;};
  egress-filter = import ./modules/egress-filter.nix {inherit pkgs lib;};

  router6-batman-wired-only = import ./modules/router6-batman-wired-only.nix {inherit pkgs lib;};
  router6-listening-sockets = import ./modules/router6-listening-sockets.nix {inherit pkgs lib;};
  router6-dnat = import ./modules/router6-dnat.nix {inherit pkgs lib;};
  router6-extra-rules = import ./modules/router6-extra-rules.nix {inherit pkgs lib;};
  router6-dns-interception-vm = import ./modules/router6-dns-interception.nix {inherit pkgs lib;};
  router6-dns-blocking = import ./modules/router6-dns-blocking.nix {inherit pkgs lib;};
  router6-dns-fallback = import ./modules/router6-dns-fallback.nix {inherit pkgs lib;};
  router6-dnssec = import ./modules/router6-dnssec.nix {inherit pkgs lib;};
  router6-network-zone-egress = import ./modules/router6-network-zone-egress.nix {inherit pkgs lib;};

  # Container-backed duplicates of the VM integration tests. Keep these
  # side-by-side with the VM checks until the output has been compared.
  router6-ipv6-container = mkContainerTest ./modules/router6-ipv6.nix;
  router6-ipv6-privacy-container = mkContainerTest ./modules/router6-ipv6-privacy.nix;
  router6-firewall-container = mkContainerTest ./modules/router6-firewall.nix;
  router6-firewall-zones-container = mkContainerTest ./modules/router6-firewall-zones.nix;
  router6-bond-bridge-container = mkContainerTest ./modules/router6-bond-bridge.nix;
  router6-device-vlans-container = mkContainerTest ./modules/router6-device-vlans.nix;
  router6-bridge-vlan-ordering-container = mkContainerTest ./modules/router6-bridge-vlan-ordering.nix;
  router6-wan-dhcp-container = mkContainerTest ./modules/router6-wan-dhcp.nix;
  router6-wan-ipv6-pd-container = mkContainerTest ./modules/router6-wan-ipv6-pd.nix;
  router6-dhcpv6-container = mkContainerTest ./modules/router6-dhcpv6.nix;
  egress-filter-container = mkContainerTest ./modules/egress-filter.nix;

  router6-batman-wired-only-container = mkContainerTest ./modules/router6-batman-wired-only.nix;
  router6-listening-sockets-container = mkContainerTest ./modules/router6-listening-sockets.nix;
  router6-dnat-container = mkContainerTest ./modules/router6-dnat.nix;
  router6-extra-rules-container = mkContainerTest ./modules/router6-extra-rules.nix;
  router6-dns-interception-vm-container = mkContainerTest ./modules/router6-dns-interception.nix;
  router6-dns-blocking-container = mkContainerTest ./modules/router6-dns-blocking.nix;
  router6-dns-fallback-container = mkContainerTest ./modules/router6-dns-fallback.nix;
  router6-dnssec-container = mkContainerTest ./modules/router6-dnssec.nix;
  router6-network-zone-egress-container = mkContainerTest ./modules/router6-network-zone-egress.nix;

  # Pure Nix evaluation tests
  nftables-dsl = import ./lib/nftables.nix {inherit pkgs lib;};
  router6-zone-system = import ./lib/router6-zone-system.nix {inherit pkgs lib;};
  router6-firewall-properties = import ./lib/router6-firewall-properties.nix {inherit pkgs lib;};
  router6-dhcp-config = import ./lib/router6-dhcp-config.nix {inherit pkgs lib;};
  router6-dnat-properties = import ./lib/router6-dnat-properties.nix {inherit pkgs lib;};
  router6-assertions = import ./lib/router6-assertions.nix {inherit pkgs lib;};
  router6-wireguard-config = import ./lib/router6-wireguard-config.nix {inherit pkgs lib;};
  router6-kresd-config = import ./lib/router6-kresd-config.nix {inherit pkgs lib;};
  router6-sysctl-properties = import ./lib/router6-sysctl-properties.nix {inherit pkgs lib;};
  router6-dyndns-config = import ./lib/router6-dyndns-config.nix {inherit pkgs lib;};
  router6-pppoe-config = import ./lib/router6-pppoe-config.nix {inherit pkgs lib;};
  router6-routes = import ./lib/router6-routes.nix {inherit pkgs lib;};
  router6-egress-properties = import ./lib/router6-egress-properties.nix {inherit pkgs lib;};
  router6-dns-interception = import ./lib/router6-dns-interception.nix {inherit pkgs lib;};
  router6-address-parsing = import ./lib/router6-address-parsing.nix {inherit pkgs lib;};
  network-helpers = import ./lib/network-helpers.nix {inherit pkgs lib;};
  network-registry = import ./lib/network-registry.nix {inherit pkgs lib;};
  network-prefix-length = import ./lib/network-prefix-length.nix {inherit pkgs lib;};
  openwrt-config = import ./lib/openwrt-config.nix {inherit pkgs lib;};
  uci-rendering = import ./lib/uci-rendering.nix {inherit pkgs lib;};
}
