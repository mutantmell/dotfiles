{ config, pkgs, lib, ... }:

let
  mkScript = name: script: pkgs.writeScriptBin name ''
    #!${pkgs.runtimeShell}
    ${script}
  '';
in {
  home.stateVersion = "22.05";
  home.username = "mjollnir";
  home.homeDirectory = "/home/mjollnir";
  
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    dig
    bitwarden-cli
    age
  ];

  programs.emacs = {
    enable = true;
    extraPackages = (epkgs: (with epkgs.melpaStablePackages; [
      magit
      lsp-mode
      haskell-mode
      yaml-mode
    ]) ++ (with epkgs.melpaPackages; [
      nix-mode
      dante
    ]));
  };

  services.emacs = {
    enable = true;
    socketActivation.enable = true;
    defaultEditor = true;
  };

  programs.git = {
    enable = true;
    userName = "mutantmell";
    userEmail = "malaguy@gmail.com";
    extraConfig = {
      credential.helper = "${
        pkgs.git.override { withLibsecret = true; }
      }/bin/git-credential-libsecret";
    };
  };

  programs.direnv.enable = true;
  services.lorri.enable = true;

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

  programs.bash = {
    enable = true;
  };

}
