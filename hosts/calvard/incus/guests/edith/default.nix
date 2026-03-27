{
  pkgs,
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    ./sops.nix
    ./modules/cc-sandbox.nix
    (import ../../../../../profiles/disko/incus-vm.nix {})
  ];

  incus-guest = {
    profile = "dev";
    parent = "br21";
    limits.memory = "16GB";
    limits.disk = "100GB";
  };

  nix.settings.experimental-features = ["nix-command" "flakes"];

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
      IPv6AcceptRA = false;
    };
    address = [
      "10.97.21.42/24"
      "fdc6:55f2:0a5e:15::2a/64"
    ];
    routes = [
      {Gateway = "10.97.21.1";}
      {Gateway = "fdc6:55f2:0a5e:15::1";}
    ];
    dns = ["10.97.21.1" "fdc6:55f2:0a5e:15::1"];
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
    keys = ["home" "deploy" "calvard"];
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

  security.pki.certificates = [(builtins.readFile pkgs.mmell.lib.data.pki.root)];

  services.cc-sandbox = {
    enable = true;
    apiUrl = "https://roer.internal/api/v1";
    authUrl = "https://auth.mutantmell.net/realms/homelab/protocol/openid-connect/token";
    registry = "creil.internal";
    caCert = builtins.toString pkgs.mmell.lib.data.pki.root;
  };

  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
