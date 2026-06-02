# Test runner for dotfiles
#
# Run all tests: ./scripts/run-checks.sh (avoid `nix flake check` — OOM risk)
# Run one: nix build .#checks.x86_64-linux.<name>
# Run interactively: nix build .#checks.x86_64-linux.<name>.driverInteractive && ./result/bin/nixos-test-driver
# Run unit tests: nix-instantiate --eval --strict tests/lib/<file>.nix
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
  disko ? null,
}:
# Router tests in sub-module
(import ./router6.nix {inherit pkgs lib;})
// {
  # Incus integration tests
  incus-container = import ./modules/incus-container.nix {inherit pkgs lib;};
  incus-vm = import ./modules/incus-vm.nix {inherit pkgs lib disko;};

  # Phantasma DNS stack (Blocky + Unbound)
  blocky-config = import ./lib/blocky-config.nix {inherit pkgs lib;};
  phantasma-dns = import ./modules/phantasma-dns.nix {inherit pkgs lib;};
  phantasma-dns-real = import ./modules/phantasma-dns-real.nix {inherit pkgs lib;};

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
    profile = import ../profiles/disko/btrfs.nix {inherit lib;};
  in
    pkgs.runCommand "disko-btrfs-check" {
      profileJson = builtins.toJSON profile;
    } ''
      echo "btrfs disko profile validated successfully"
      echo "$profileJson" > $out
    '';

  disko-btrfs-l2arc = let
    profile = import ../profiles/disko/btrfs.nix {
      l2arcSize = "32G";
      inherit lib;
    };
  in
    pkgs.runCommand "disko-btrfs-l2arc-check" {
      profileJson = builtins.toJSON profile;
    } ''
      echo "btrfs+l2arc disko profile validated successfully"
      echo "$profileJson" > $out
    '';
}
