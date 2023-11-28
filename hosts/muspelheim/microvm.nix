{ config, pkgs, microvm, ... }:

{
  microvm = rec {
    vms = builtins.mapAttrs (name: dir: {
      inherit pkgs;
      config = pkgs.mmell.lib.builders.mk-microvm (import (./guests + "/${dir}"));
    }) (builtins.readDir ./guests);
    autostart = builtins.attrNames vms;
  };
}
