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
      # Container will get IP from Incus DHCP or static config
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    # Override if you want static IP:
    # networkConfig = {
    #   Address = [ "10.0.20.42/24" ];
    #   Gateway = "10.0.20.1";
    #   DNS = [ "10.0.20.1" ];
    # };
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

  # Security certificates (if needed)
  # security.pki.certificates = [ (builtins.readFile ...) ];

  # TODO: If you need SOPS secrets, set them up here
  # For now, containers can access secrets via bind mounts or copy

  # TODO: If you need the proxy configuration, migrate it here
  # imports = [ ./proxy.nix ];

  system.stateVersion = "24.05";
}
