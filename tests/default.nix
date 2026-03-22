# Test runner for dotfiles
#
# Run all tests: ./scripts/run-checks.sh (avoid `nix flake check` — OOM risk)
# Run one: nix build .#checks.x86_64-linux.<name>
# Run interactively: nix build .#checks.x86_64-linux.<name>.driverInteractive && ./result/bin/nixos-test-driver
# Run unit tests: nix-instantiate --eval --strict tests/lib/<file>.nix
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}:
# Router tests in sub-module
(import ./router6.nix {inherit pkgs lib;})
// {
  # Incus integration tests
  deployd = import ./modules/deployd.nix {inherit pkgs lib;};
  incus-container = import ./modules/incus-container.nix {inherit pkgs lib;};
  incus-vm = import ./modules/incus-vm.nix {inherit pkgs lib;};

  # Disko profile validation
  disko-tmpfs = let
    profile = import ../profiles/disko/tmpfs.nix {};
  in
    pkgs.runCommand "disko-tmpfs-check" {
      profileJson = builtins.toJSON profile;
    } ''
      echo "tmpfs disko profile validated successfully"
      echo "$profileJson" > $out
    '';

  disko-btrfs = let
    profile = import ../profiles/disko/btrfs.nix {};
  in
    pkgs.runCommand "disko-btrfs-check" {
      profileJson = builtins.toJSON profile;
    } ''
      echo "btrfs disko profile validated successfully"
      echo "$profileJson" > $out
    '';
}
