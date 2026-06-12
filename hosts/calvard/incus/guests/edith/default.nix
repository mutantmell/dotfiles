{
  pkgs,
  config,
  lib,
  modulesPath,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost "edith") host zone;
in {
  imports = [
    ./sops.nix
    (import ../../../../../profiles/disko/incus-vm.nix {})
  ];

  incus-guest = {
    profile = "dev";
    parent = "br21";
    limits.memory = "16GB";
    limits.disk = "100GB";
  };

  nix.settings.experimental-features = ["nix-command" "flakes" "auto-allocate-uids" "uid-range"];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  networking.hostName = "edith";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # Static network configuration (VLAN 21 / lab, hostId 42)
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
      {Gateway = zone.gateway6;}
    ];
    dns = [zone.gateway4 zone.gateway6];
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

  users.users.mutantmell = {
    isNormalUser = true;
    extraGroups = ["wheel" "systemd-journal"];
    uid = 1000;
  };
  common.openssh = {
    enable = true;
    users = ["mutantmell" "root"];
    keys = ["home" "deploy" "calvard" "ios"];
    allowPassword = true;
    principals = {
      root = ["admin"];
      mutantmell = ["admin"];
    };
  };

  # Session-resilient SSH alternative (survives sleep, WiFi drops)
  services.eternal-terminal = {
    enable = true;
    port = 2022;
  };
  networking.firewall.allowedTCPPorts = [2022];

  common.internal-pki.enable = true;

  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
