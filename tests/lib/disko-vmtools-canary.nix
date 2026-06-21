# Canary for the temporary mk-incus-vm vmTools compatibility shim.
#
# This should fail after upstream disko stops passing an aggregate module tree
# as vmTools.kernel. When it fails, remove the shim in flake.nix and this check.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
  disko,
}: let
  source =
    if disko == null
    then builtins.throw "disko-vmtools-canary requires the pinned disko flake input"
    else builtins.readFile "${disko}/lib/make-disk-image.nix";

  stillNeedsShim = lib.hasInfix "kernel = pkgs.aggregateModules (" source;
in
  if stillNeedsShim
  then
    pkgs.runCommand "disko-vmtools-canary" {} ''
      echo "disko still passes aggregate modules as vmTools.kernel; keep the local compatibility shim"
      echo ok > "$out"
    ''
  else
    builtins.throw ''
      disko-vmtools-canary: upstream disko no longer appears to pass an
      aggregate module tree as vmTools.kernel. Remove the mk-incus-vm vmTools
      compatibility shim in flake.nix, remove this canary, and rebuild erebonia.
    ''
