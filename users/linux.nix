{ config, pkgs, lib, ... }:

{
  home.homeDirectory = "/home/mjollnir";
  services.lorri.enable = true;
}
