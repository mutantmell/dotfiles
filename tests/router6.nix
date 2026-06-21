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
    };
in {
  # Integration tests default to the container driver. Keep VM checks only for
  # behavior containers cannot prove independently: interface renaming in a
  # guest kernel/userspace boundary and batman-adv module loading.
  router6-ipv6 = mkContainerTest ./modules/router6-ipv6.nix;
  router6-ipv6-privacy = mkContainerTest ./modules/router6-ipv6-privacy.nix;
  router6-firewall = mkContainerTest ./modules/router6-firewall.nix;
  router6-firewall-zones = mkContainerTest ./modules/router6-firewall-zones.nix;
  router6-bond-bridge = mkContainerTest ./modules/router6-bond-bridge.nix;
  router6-device-vlans = mkContainerTest ./modules/router6-device-vlans.nix;
  router6-bridge-vlan-ordering = mkContainerTest ./modules/router6-bridge-vlan-ordering.nix;
  router6-wan-dhcp = mkContainerTest ./modules/router6-wan-dhcp.nix;
  router6-wan-ipv6-pd = mkContainerTest ./modules/router6-wan-ipv6-pd.nix;
  router6-dhcpv6 = mkContainerTest ./modules/router6-dhcpv6.nix;
  egress-filter = mkContainerTest ./modules/egress-filter.nix;

  router6-batman-wired-only = mkContainerTest ./modules/router6-batman-wired-only.nix;
  router6-listening-sockets = mkContainerTest ./modules/router6-listening-sockets.nix;
  router6-dnat = mkContainerTest ./modules/router6-dnat.nix;
  router6-extra-rules = mkContainerTest ./modules/router6-extra-rules.nix;
  router6-dns-interception-integration = mkContainerTest ./modules/router6-dns-interception.nix;
  router6-dns-blocking = mkContainerTest ./modules/router6-dns-blocking.nix;
  router6-dns-fallback = mkContainerTest ./modules/router6-dns-fallback.nix;
  router6-dnssec = mkContainerTest ./modules/router6-dnssec.nix;
  router6-network-zone-egress = mkContainerTest ./modules/router6-network-zone-egress.nix;

  router6-interface-rename-vm = import ./modules/router6-interface-rename-vm.nix {inherit pkgs lib;};
  router6-batman-module-vm = import ./modules/router6-batman-module-vm.nix {inherit pkgs lib;};

  # Pure Nix evaluation tests
  nftables-dsl = import ./lib/nftables.nix {inherit pkgs lib;};
  router6-zone-system = import ./lib/router6-zone-system.nix {inherit pkgs lib;};
  router6-firewall-properties = import ./lib/router6-firewall-properties.nix {inherit pkgs lib;};
  router6-dhcp-config = import ./lib/router6-dhcp-config.nix {inherit pkgs lib;};
  router6-dnat-properties = import ./lib/router6-dnat-properties.nix {inherit pkgs lib;};
  router6-assertions = import ./lib/router6-assertions.nix {inherit pkgs lib;};
  router6-wireguard-config = import ./lib/router6-wireguard-config.nix {inherit pkgs lib;};
  router6-kresd-config = import ./lib/router6-kresd-config.nix {inherit pkgs lib;};
  router6-dns-blocking-config = import ./lib/router6-dns-blocking-config.nix {inherit pkgs lib;};
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
