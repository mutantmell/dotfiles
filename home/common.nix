{ config, pkgs, lib, ... }:

{
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
      js2-mode
    ]) ++ (with epkgs.melpaPackages; [
      nix-mode
      dante
    ]));
  };

  programs.git = {
    enable = true;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
