{ config, pkgs, lib, ... }:

{
  home.homeDirectory = "/home/mjollnir";
  programs.direnv.enable = true;
  services.lorri.enable = true;
}
