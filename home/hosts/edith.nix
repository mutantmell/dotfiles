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
    caCert = builtins.toString pkgs.mmell.lib.data.pki.root;
    dnsServers = ["10.97.100.1"];
    memoryLimit = "8g";
    cpuLimit = "4";
    flakePath = "/home/mutantmell/git/dotfiles";
    forgejoTokenFile = config.sops.secrets."cc-sandbox-forgejo-token".path;
  };
}
