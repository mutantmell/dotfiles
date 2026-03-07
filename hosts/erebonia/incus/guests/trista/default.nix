{
  pkgs,
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    ./sops.nix
  ];

  incus-guest = {
    profile = "dmz-vm";
    network = "incusbr100";
  };

  nix.settings.experimental-features = ["nix-command" "flakes"];

  networking.hostName = "trista";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # Static network configuration (VLAN 100 / DMZ, hostId 51)
  systemd.network.enable = true;
  services.resolved.enable = true;
  systemd.network.networks."50-enp5s0" = {
    matchConfig.Name = "enp5s0";
    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
    };
    address = [
      "10.97.100.51/24" # Primary
      "10.0.100.51/24" # Legacy (remove after migration)
      "fdc6:55f2:0a5e:64::33/64"
    ];
    routes = [
      {Gateway = "10.97.100.1";}
      {Gateway = "fdc6:55f2:0a5e:64::1";}
    ];
    dns = ["10.97.100.1" "10.0.100.1" "fdc6:55f2:0a5e:64::1"];
  };

  common.openssh = {
    enable = true;
    keys = ["deploy" "erebonia"];
  };

  environment.systemPackages = with pkgs; [
    home-manager
    git
    vim
    curl
    wget
  ];

  nix.settings = {
    allowed-users = ["@wheel"];
    trusted-users = ["root" "@wheel"];
  };

  time.timeZone = "UTC";

  system.stateVersion = "25.11";
}
