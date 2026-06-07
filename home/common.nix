{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./modules/java-versions.nix
    ./modules/kube.nix
    ./modules/dev-machine.nix
  ];

  home.packages = with pkgs; [
    nixfmt
    dig
    bitwarden-cli
    age
    (aspellWithDicts (ds: [
      ds.en
      ds.en-computers
      ds.en-science
    ]))
  ];

  programs.emacs = {
    enable = true;
    extraPackages = epkgs:
      (with epkgs.melpaStablePackages; [
        magit
        lsp-mode
        haskell-mode
        yaml-mode
        json-mode
        js2-mode
      ])
      ++ (with epkgs.melpaPackages; [
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

  programs.bash = {
    enable = true;
  };

  programs.claude-code = {
    enable = true;
  };

  programs.jujutsu = {
    enable = true;
  };

  programs.tmux = {
    enable = true;
    newSession = true;
    plugins = let
      inherit (pkgs) tmuxPlugins;
    in [
      tmuxPlugins.continuum
    ];
  };

  programs.htop = {
    enable = true;
    settings = {
      treeView = true;
    };
  };
}
