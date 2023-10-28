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
  };

  imports = [
    ./common.nix
  ] ++ (builtins.map (lang: {
    "agda" = ./lang/agda.nix;
  }.lang) (home-conf.langs or [])) ++ (
    option-null ({
      "mjollnir" = ./mjollnir.nix;
    }.${home-conf.user} or null)
  ) ++ (
    lib.optional (home-conf.is-graphical or false) ./graphical.nix
  ) ++ (
    home-conf.extraModules or []
  );
}
