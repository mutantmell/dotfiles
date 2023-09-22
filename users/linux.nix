{ config, pkgs, lib, ... }:

{

  home.packages = with pkgs; [
    dig
    bitwarden-cli
    age
  ];

  programs.tmux = {
    enable = true;
    newSession = true;
  };

  programs.htop = {
    enable = true;
    settings = {
      treeView = true;
    };
  };

}
