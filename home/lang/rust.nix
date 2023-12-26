{ config, pkgs, lib, ... }:

{
  programs.emacs = {
    extraPackages = (epkgs: [ epkgs.rust-mode ]);
  };
}
