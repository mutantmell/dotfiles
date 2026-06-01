{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.common.internal-pki;
  inherit (pkgs.mmell.lib.data) pki;
in {
  options.common.internal-pki = {
    enable = lib.mkEnableOption "trust for the internal step-ca PKI (root + intermediate) in the system TLS store";
  };

  config = lib.mkIf cfg.enable {
    security.pki.certificateFiles = [
      pki.root
      pki.intermediate
    ];
  };
}
