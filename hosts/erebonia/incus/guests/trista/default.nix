{
  pkgs,
  config,
  lib,
  modulesPath,
  ...
}: let
  hostname = "trista";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  imports = [
    ./sops.nix
    (import ../../../../../profiles/disko/incus-vm.nix {})
  ];

  incus-guest = {
    profile = "dmz-vm";
    parent = "uplink.100";
    nictype = "macvlan";
  };

  nix.settings.experimental-features = ["nix-command" "flakes"];

  networking.hostName = hostname;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # Static network configuration (VLAN 100 / DMZ)
  systemd.network.enable = true;
  services.resolved.enable = true;
  systemd.network.networks."50-enp5s0" = {
    matchConfig.Name = "enp5s0";
    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = true;
      IPv6PrivacyExtensions = "yes";
    };
    address = [host.cidr4 host.cidr6];
    routes = [
      {Gateway = zone.gateway4;}
      {
        Destination = "fdc6:55f2:0a5e::/48";
        Gateway = zone.gateway6;
      }
    ];
    dns = [zone.gateway4 zone.gateway6];
  };

  common.openssh = {
    enable = true;
    keys = ["deploy" "erebonia" "edith"];
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

  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
