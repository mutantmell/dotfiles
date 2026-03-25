# Project-specific wiring for the deployd container deployment service.
#
# - Wires registry allowlist to project registries
# - Integrates persistent paths with impermanence
# - Wires registry/hostname allowlists to project values
# - Adds step-ca root cert trust for registry TLS
{
  config,
  lib,
  pkgs,
  options,
  ...
}: let
  cfg = config.common.deployd;
  impCfg = config.common.impermanence;
  hasDeployd = options ? deployd;
in {
  options.common.deployd = {
    enable = lib.mkEnableOption "common deployd host options";
  };

  config = lib.mkMerge [
    # Wire deployd options to project-specific values
    (lib.optionalAttrs hasDeployd (lib.mkIf cfg.enable {
      deployd = {
        enable = true;
        registryAllowlist = ["creil.internal"];
        hostnameAllowlist = [".internal"];
      };

      # Trust step-ca root CA so Podman can pull from creil.internal over HTTPS
      security.pki.certificateFiles = [pkgs.mmell.lib.data.pki.root];
    }))

    # Persist deployd state via impermanence
    (lib.optionalAttrs hasDeployd (lib.mkIf (cfg.enable && impCfg.enable) {
      environment.persistence.${impCfg.persistDir}.directories = [
        {
          directory = "/etc/containers/systemd";
          user = "root";
          group = "root";
        }
        {
          directory = "/var/log/deployd";
          user = "deployd-helper";
          group = "deployd-helper";
        }
      ];
    }))
  ];
}
