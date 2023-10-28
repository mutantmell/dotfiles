{ config, pkgs, lib, home-conf, ... }:

let
  is-graphical = home-conf.is-graphical or false;
  langs = home-conf.langs or [];
  optional-nonnull = x: if x != null then [x] else [];
in {
  programs.home-manager.enable = true;

  home.username = home-conf.user;
  home.homeDirectory = home-conf.home or (
    if pkgs.stdenv.isDarwin then "/Users/${home-conf.user}" else "/home/${home-conf.user}"
  );
  home.stateVersion = "23.05";

  imports = [
    ./common.nix
  ] ++ (builtins.map (lang: {
     "agda" = ./lang/agda.nix;
  }.lang) langs) ++ (optional-nonnull ({
    "mjollnir" = ./mjollnir.nix;
  }.${home-conf.user} or null)) ++ (
    lib.optional is-graphical ./graphical.nix
  );
  
}
