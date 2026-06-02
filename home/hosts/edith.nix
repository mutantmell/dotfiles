# edith-specific home-manager config: cc-sandbox + sops
{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ../modules/cc-sandbox.nix
  ];

  # Interactive sops loads the admin identity from passage on each invocation
  # (no plaintext at rest under ~/.config/sops/age/).
  home.sessionVariables.SOPS_AGE_KEY_CMD = "passage show sops/key";

  # sops-nix home-manager: derive age key from user's SSH ed25519 key
  sops = {
    defaultSopsFile = ./edith/secrets.yaml;
    age.sshKeyPaths = ["${config.home.homeDirectory}/.ssh/id_ed25519"];
    secrets."cc-sandbox-forgejo-token" = {};
  };

  cc-sandbox = {
    enable = true;
    apiUrl = "https://roer.internal/api/v1";
    authBaseUrl = "https://auth.mutantmell.net/realms/homelab";
    registry = "creil.internal";
    caCert = "${pkgs.mmell.lib.data.pki.root}";
    dnsServers = ["10.97.100.1"];
    memoryLimit = "8g";
    cpuLimit = "4";
    flakePath = "/home/mutantmell/git/dotfiles";
    forgejoTokenFile = config.sops.secrets."cc-sandbox-forgejo-token".path;
  };
}
