{
  config,
  lib,
  ...
}: let
  cfg = config.promtail-client;
in {
  options.promtail-client = {
    enable = lib.mkEnableOption "Promtail log shipping to Loki";
    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://tharbad.internal:3100/loki/api/v1/push";
      description = "Loki push API endpoint URL";
    };
  };

  # TEMPORARILY DISABLED: nixpkgs removed `services.promtail` (promtail reached
  # end-of-life). Migration to grafana-alloy or fluent-bit is pending. Until
  # then, this module is a no-op so existing `promtail-client.enable = true`
  # call sites keep their intent without breaking evaluation.
  config = lib.mkIf cfg.enable {};
}
