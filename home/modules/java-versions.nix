{ config, lib, pkgs, ... }:

let
  cfg = config.programs.java.versions;
in {
  options.programs.java.versions = {
    enable = lib.mkEnableOption "java version management";
    versions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = let
      path = ver: ".local/share/java/${ver}";
      package = ver: pkgs.${"openjdk" + ver};
    in builtins.listToAttrs (builtins.map (v: {
      name = path v;
      value.source = config.lib.file.mkOutOfStoreSymlink "${package v}";
    }) cfg.versions);
  };
}
