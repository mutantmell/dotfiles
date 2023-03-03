{ config, pkgs, lib, ... }:

{
  programs.firefox = lib.mkIf extra-conf.has-gui {
    enable = true;
  };
}
