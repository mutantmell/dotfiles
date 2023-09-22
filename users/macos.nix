{ config, pkgs, lib, ... }:

{
  programs.zsh.enable = true;
  programs.direnv.enableZshIntegration = true;
}
