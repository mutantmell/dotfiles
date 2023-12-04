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

  programs.git.extraConfig = {
    credential.helper = "${
      pkgs.git.override { withLibsecret = true; }
    }/bin/git-credential-libsecret";
  };

  programs.bash = {
    enable = true;
  };

  programs.tmux = {
    enable = true;
    newSession = true;
    plugins = let
      inherit (pkgs) tmuxPlugins;
    in [
      tmuxPlugins.resurrect
    ];
  };

  programs.htop = {
    enable = true;
    settings = {
      treeView = true;
    };
  };

}
