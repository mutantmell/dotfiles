{
  user,
  langs ? [],
  is-darwin ? false,
  is-wsl ? false,
  is-graphical ? false,
  home ? null,
  extraPackages ? [],
  extraModules ? [],
}: {
  config,
  pkgs,
  lib,
  ...
}: {
  programs.home-manager.enable = true;

  home = {
    username = user;
    homeDirectory =
      if home != null
      then home
      else if is-darwin
      then "/Users/${user}"
      else "/home/${user}";
    stateVersion = "25.11";
    packages = extraPackages;
  };

  imports =
    [
      ./common.nix
    ]
    ++ (
      builtins.map (lang: ./lang + "/${lang}.nix") langs
    )
    ++ (
      let
        path = ./user + "/${user}.nix";
      in
        lib.optional (builtins.pathExists path) path
    )
    ++ (
      lib.optional is-darwin ./darwin.nix
    )
    ++ (
      lib.optional (!is-darwin && !is-wsl) ./linux.nix
    )
    ++ (
      lib.optional is-wsl ./wsl.nix
    )
    ++ (
      lib.optional is-graphical ./graphical.nix
    )
    ++ extraModules;
}
