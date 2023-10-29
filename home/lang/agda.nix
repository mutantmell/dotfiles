{ config, pkgs, lib, ... }:

{
  home.packages = [
    (pkgs.agda.withPackages (p: [ p.standard-library ]))
  ];

  programs.emacs = {
    extraConfig = ''
      (load-file (let ((coding-system-for-read 'utf-8))
                (shell-command-to-string "agda-mode locate")))
    '';
    extraPackages = (epkgs: [ epkgs.agda2-mode ]);
  };
}
