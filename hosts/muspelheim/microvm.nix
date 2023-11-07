{ config, pkgs, microvm, ... }:

{
  microvm.autostart = [
    "surtr2"
  ];

  microvm.vms = builtins.mapAttrs (name: config-path: {
    inherit pkgs;
    config = pkgs.mmell.lib.builders.mk-microvm (import config-path);
  }) {
    surtr2 = ./guests/surtr2;
    ymir2 = ./guests/ymir2;
  };
}
