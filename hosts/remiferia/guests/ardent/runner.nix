{ config, pkgs, ... }:
{
  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.default = {
      enable = true;
      name = "ardent";
      url = "https://ardent.local";
      tokenFile = config.sops.secrets."forgejo-runner-token".path;
      labels = [
        "nix:host"
        "ubuntu-latest:docker://node:20-bookworm"
      ];
      settings.runner.fetch_interval = "30s";
    };
  };

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };

  environment.persistence."/persist" = {
    directories = [
      "/var/lib/containers"
    ];
  };
}
