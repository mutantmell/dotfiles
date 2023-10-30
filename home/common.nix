{ config, pkgs, lib, ... }:

{
  imports = [
    ./modules/java-versions.nix
  ];

  home.packages = with pkgs; [
    nixfmt
    (aspellWithDicts (ds: [
      ds.en
      ds.en-computers
      ds.en-science
    ]))
  ];

  programs.emacs = {
    enable = true;
    extraPackages = epkgs: (with epkgs.melpaStablePackages; [
      magit
      lsp-mode
      haskell-mode
      yaml-mode
      json-mode
      js2-mode
    ]) ++ (with epkgs.melpaPackages; [
      nix-mode
      dante
    ]);
  };

  programs.git = {
    enable = true;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
