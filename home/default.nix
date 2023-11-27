{ config, pkgs, lib, home-conf, ... }:

let
  option-null = x: if x != null then [x] else [];
in {
  programs.home-manager.enable = true;

  home = {
    username = home-conf.user;
    homeDirectory = home-conf.home or (
      if pkgs.stdenv.isDarwin then "/Users/${home-conf.user}" else "/home/${home-conf.user}"
    );
    stateVersion = "23.05";
    packages = ((
      home-conf.extraPackages or (pkgs: [])
    ) pkgs);
  };

  imports = let
    extra-modules = home-conf.extraModules or [];
  in [
    ./common.nix
  ] ++ (
    builtins.map (lang: ./lang + "/${lang}.nix") (home-conf.langs or [])
  ) ++ (
    let path = ./user + "/${home-conf.user}.nix";
    in lib.optional (builtins.pathExists path) path
  ) ++ (
    lib.optional (home-conf.is-graphical or false) ./graphical.nix
  ) ++ (
    if builtins.isFunction extra-modules
    then extra-modules pkgs
    else extra-modules
  );
}
