# Test runner for dotfiles
#
# Run all tests: nix flake check --print-build-logs
# Run one: nix build .#checks.x86_64-linux.<name>
# Run interactively: nix build .#checks.x86_64-linux.<name>.driverInteractive && ./result/bin/nixos-test-driver
# Run unit tests: nix-instantiate --eval --strict tests/lib/<file>.nix

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

# Router tests in sub-module
(import ./router6.nix { inherit pkgs lib; })
// {
  # Incus integration tests
  incus-container = import ./modules/incus-container.nix { inherit pkgs lib; };
  incus-vm = import ./modules/incus-vm.nix { inherit pkgs lib; };

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
