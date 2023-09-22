{ config, pkgs, lib, ... }:

{
  home.stateVersion = "22.05";
  
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    nixfmt
  ];

  programs.emacs = {
    enable = true;
    extraPackages = (epkgs: [
      epkgs.agda2-mode
    ] ++ (with epkgs.melpaStablePackages; [
      magit
      lsp-mode
      haskell-mode
      yaml-mode
      json-mode
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
