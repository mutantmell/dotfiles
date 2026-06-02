# edith-specific home-manager config: sops + passage admin identity
{
  config,
  pkgs,
  lib,
  ...
}: {
  # Interactive sops loads the admin identity from passage on each invocation
  # (no plaintext at rest under ~/.config/sops/age/).
  home.sessionVariables.SOPS_AGE_KEY_CMD = "passage show sops/key";
}
