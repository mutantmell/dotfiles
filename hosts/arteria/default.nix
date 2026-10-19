{pkgs, ...}: {
  imports = [./hardware-configuration.nix ./disk.nix ./router.nix];

  networking.hostName = "arteria";
  common.internal-pki.enable = true;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Match the onboard Ethernet controller before predictable-name assignment.
  # This assumes precisely one PCI Ethernet NIC; Wi-Fi and USB NICs do not match.
  systemd.network.links."10-arteria-uplink" = {
    matchConfig = {
      Type = "ether";
      Path = "pci-*";
    };
    linkConfig.Name = "uplink";
  };

  common.openssh = {
    enable = true;
    users = ["root"];
    keys = ["deploy" "home" "edith"];
  };
  # Preserve the console password in /persist for local recovery (see disk.nix).
  # SSH still uses the repository's key-only common.openssh policy.
  users.mutableUsers = true;
  environment.systemPackages = with pkgs; [git tcpdump ethtool];
  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.settings.auto-optimise-store = true;
  # Retain rollback generations on this gateway; collect only aged generations.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  services.journald.settings.Journal.SystemMaxUse = "100M";
  system.stateVersion = "26.05";
}
