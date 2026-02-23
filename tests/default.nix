# Test runner for dotfiles
#
# Run all tests: nix build .#checks.x86_64-linux.router6-ipv6
# Run interactively: nix build .#checks.x86_64-linux.router6-ipv6.driverInteractive && ./result/bin/nixos-test-driver
# Run unit tests: nix-instantiate --eval --strict tests/lib/nftables.nix

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

{
  # NixOS integration tests
  router6-ipv6 = import ./modules/router6-ipv6.nix { inherit pkgs lib; };
  router6-firewall = import ./modules/router6-firewall.nix { inherit pkgs lib; };
  router6-firewall-zones = import ./modules/router6-firewall-zones.nix { inherit pkgs lib; };
  router6-bond-bridge = import ./modules/router6-bond-bridge.nix { inherit pkgs lib; };
  router6-device-vlans = import ./modules/router6-device-vlans.nix { inherit pkgs lib; };
  router6-bridge-vlan-ordering = import ./modules/router6-bridge-vlan-ordering.nix { inherit pkgs lib; };
  egress-filter = import ./modules/egress-filter.nix { inherit pkgs lib; };
  # Temporary: pre-deployment validation for thebeyond router config.
  # Remove after successful deployment to physical hardware.
  router6-thebeyond = import ./modules/router6-thebeyond.nix { inherit pkgs lib; };

  # Unit tests (pure Nix evaluation)
  nftables-dsl = import ./lib/nftables.nix { inherit pkgs lib; };
  router6-firewall-snapshot = import ./lib/router6-firewall-snapshot.nix { inherit pkgs lib; };
  # Temporary: pre-deployment validation. Remove after successful deployment.
  thebeyond-firewall-snapshot = import ./lib/thebeyond-firewall-snapshot.nix { inherit pkgs lib; };
  router6-zone-system = import ./lib/router6-zone-system.nix { inherit pkgs lib; };
  network-helpers = import ./lib/network-helpers.nix { inherit pkgs lib; };

  # Disko profile validation
  disko-router = let
    profile = import ../profiles/disko/router.nix {};
  in pkgs.runCommand "disko-router-check" {
    profileJson = builtins.toJSON profile;
  } ''
    echo "Router disko profile validated successfully"
    echo "$profileJson" > $out
  '';

  disko-vm-host = let
    profile = import ../profiles/disko/vm-host.nix {};
  in pkgs.runCommand "disko-vm-host-check" {
    profileJson = builtins.toJSON profile;
  } ''
    echo "VM host disko profile validated successfully"
    echo "$profileJson" > $out
  '';
}
