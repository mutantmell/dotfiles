{ config, lib, ... }:

let
  cfg = config.common.microvm;
in {
  options.common.microvm = {
    enable = lib.mkEnableOption "common microvm host options";
    uid = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        Stable UID for the microvm user. Pinned so that deploy scripts can
        chown guest directories (e.g. /persist/guests/*/images) before the
        first NixOS boot. The kvm group GID (302) is already stable in NixOS.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.microvm.uid = cfg.uid;
  };
}
