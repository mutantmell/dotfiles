{ pkgs, config, lib, modulesPath, ... }:
{
  imports = [
    ./sops.nix
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "messeldam";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # Static network configuration (VLAN 20 / trusted, hostId 42)
  systemd.network.enable = true;
  services.resolved.enable = true;
  systemd.network.networks."50-enp5s0" = {
    matchConfig.Name = "enp5s0";
    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
    };
    address = [
      "10.97.20.42/24"   # Primary
      "10.0.20.42/24"    # Legacy (remove after migration)
      "fdc6:55f2:0a5e:14::2a/64"
    ];
    routes = [
      { Gateway = "10.97.20.1"; }
      { Gateway = "fdc6:55f2:0a5e:14::1"; }
    ];
    dns = [ "10.97.20.1" "10.0.20.1" "fdc6:55f2:0a5e:14::1" ];
  };

  common.openssh = {
    enable = true;
    keys = [ "deploy" "calvard" ];
  };

  environment.systemPackages = with pkgs; [
    home-manager
    git
    vim
    curl
    wget
  ];

  nix.settings = {
    allowed-users = [ "@wheel" ];
    trusted-users = [ "root" "@wheel" ];
  };

  time.timeZone = "UTC";

  system.stateVersion = "25.11";
}
