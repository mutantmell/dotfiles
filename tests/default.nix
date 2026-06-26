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
let
  mkContainerTest = path:
    import path {
      inherit pkgs lib;
    };
in
  (import ./router6.nix {inherit pkgs lib;})
  // {
    cert-expiry = import ./lib/cert-expiry.nix {inherit pkgs lib;};
    ci-summary-comment-post = import ./lib/ci-summary-comment-post.nix {inherit pkgs lib;};
    ci-summary-render = import ./lib/ci-summary-render.nix {inherit pkgs lib;};
    disko-vmtools-canary = import ./lib/disko-vmtools-canary.nix {
      inherit pkgs lib disko;
    };

    # Phantasma DNS stack
    phantasma-dns-real = mkContainerTest ./modules/phantasma-dns-real.nix;

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
