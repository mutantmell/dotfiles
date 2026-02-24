{ pkgs, config, lib, modulesPath, ... }:
{

  # Enable flakes and nix command
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Networking
  networking.hostName = "ordis";
  networking.useHostResolvConf = false;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # Use systemd-networkd for network configuration
  systemd.network.enable = true;
  services.resolved.enable = true;
  systemd.network.networks."50-eth0" = {
    matchConfig.Name = "eth0";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
  };

  # Users
  # TODO: Add your user accounts here
  # Root user configured via common.openssh module with SSH keys

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";  # For initial setup, change after
      PasswordAuthentication = true;  # For initial setup, change after
    };
  };

  # Install home-manager for user package management
  environment.systemPackages = with pkgs; [
    home-manager
    git
    vim
    curl
    wget
  ];

  # Nix configuration for user autonomy
  nix.settings = {
    allowed-users = [ "@wheel" ];
    trusted-users = [ "root" "@wheel" ];
  };

  # Time zone
  time.timeZone = "UTC";

  system.stateVersion = "25.11";
}
