{ config, pkgs, ... }:


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
    htop
    tmux
    bitwarden-cli
    git-secret

    colmena
    age
    sops

    step-cli
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

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.bash = {
    enable = true;
  };

}
