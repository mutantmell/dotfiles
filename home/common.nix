{ config, pkgs, lib, ... }:

{
  home.stateVersion = "22.05";
  
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    nixfmt
  ];

  programs.emacs = {
    enable = true;
    extraConfig = ''
      (load-file (let ((coding-system-for-read 'utf-8))
                (shell-command-to-string "agda-mode locate")))
    '';
    extraPackages = (epkgs: [
      epkgs.agda2-mode
    ] ++ (with epkgs.melpaStablePackages; [
      magit
      lsp-mode
      haskell-mode
      yaml-mode
      json-mode
      js2-mode
    ]) ++ (with epkgs.melpaPackages; [
      nix-mode
      dante
    ]));
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

}
