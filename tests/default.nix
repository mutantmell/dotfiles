# Test runner for dotfiles
#
# Run all tests: nix build .#checks.x86_64-linux.router6-ipv6
# Run interactively: nix build .#checks.x86_64-linux.router6-ipv6.driverInteractive && ./result/bin/nixos-test-driver

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

{
  # NixOS integration tests
  router6-ipv6 = import ./modules/router6-ipv6.nix { inherit pkgs lib; };
  router6-firewall = import ./modules/router6-firewall.nix { inherit pkgs lib; };
}
