{ config, pkgs, lib, ... }:

{

  home.packages = with pkgs; [
    dig
    bitwarden-cli
    age
  ];

  services.emacs = {
    enable = true;
    socketActivation.enable = true;
    defaultEditor = true;
  };

  programs.bash = {
    enable = true;
  };

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
