{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = [
    # keep this line if you use bash
    pkgs.bashInteractive

    pkgs.colmena
    pkgs.sops
  ];
}
