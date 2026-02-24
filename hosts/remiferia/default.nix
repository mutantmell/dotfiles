{ config, pkgs, ... }:

let
  hostname = "remiferia";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports =
    [
      ./hardware-configuration.nix
      ./sops.nix
      ./nas.nix
      ./monit.nix
      ./microvm.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.extraPools = [ "data" ];

  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;
  services.smartd.enable = true;

  services.ntp.enable = true;
  time.timeZone = "UTC";

  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    MaxFileSec=7day
  '';

  environment.systemPackages = [
    pkgs.git
    pkgs.wget
    pkgs.tmux
    pkgs.htop
  ];

  networking = {
    hostName = hostname;
    hostId = "9f034bc8";
    useNetworkd = true;
    dhcpcd.enable = false;
  };

  systemd.network = {
    enable = true;
    netdevs."20-br20" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br20";
    };
    netdevs."20-br100" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br100";
    };
    netdevs."20-enp4s0.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp4s0.11";
      vlanConfig.Id = 11;
    };
    netdevs."20-enp4s0.20" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp4s0.20";
      vlanConfig.Id = 20;
    };
    netdevs."20-enp4s0.100" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp4s0.100";
      vlanConfig.Id = 100;
    };
    networks."20-enp4s0" = {
      matchConfig.Name = "enp4s0";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "enp4s0.11"
        "enp4s0.20"
        "enp4s0.100"
      ];
    };
    networks."20-enp4s0.11" = {
      matchConfig.Name = "enp4s0.11";
      networkConfig.DHCP = "no";
      networkConfig.IPv6AcceptRA = false;
      networkConfig.Address = [ host.cidr4 host.cidr4Legacy host.cidr6 ];
      networkConfig.MulticastDNS = true;
      networkConfig.LLMNR = true;
      networkConfig.DNS = [ zone.gateway4 zone.gateway6 ];
      routes = [
        { Gateway = zone.gateway4; }
        { Gateway = zone.gateway6; }
      ];
    };
    networks."20-vm20-bridge" = {
      matchConfig.Name = [ "enp4s0.20" "vm-20-*" ];
      networkConfig.Bridge = "br20";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-vm100-bridge" = {
      matchConfig.Name = [ "enp4s0.100" "vm-100-*" ];
      networkConfig.Bridge = "br100";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br20" = {
      matchConfig.Name = "br20";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br100" = {
      matchConfig.Name = "br100";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
  };
  services.resolved.enable = true;

  # Host-based input firewall
  networking.firewall = {
    enable = true;
    extraInputRules = ''
      # SSH from router + vHOME, drop all else (both 10.97 + 10.0 legacy)
      ip saddr { ${zone.gateway4}, ${zone.gateway4Legacy}, ${net.networks.trusted.subnet4}, ${net.networks.trusted.subnet4Legacy} } tcp dport 22 accept
      ip6 saddr { ${zone.gateway6}, ${net.networks.trusted.subnet6} } tcp dport 22 accept
      tcp dport 22 drop
    '';
  };

  services.avahi.enable = true;
  services.avahi.publish.enable = true;
  services.avahi.publish.addresses = true;

  common.openssh = {
    enable = true;
    keys = [ "deploy" "home" ];
  };

  users.users.mjollnir = {
    isNormalUser = true;
    description = "samba client user";
    group = "mjollnir";
  };
  users.groups.mjollnir = {};

  home-manager.users.root = {
    home.stateVersion = "23.11";
    programs.git = {
      enable = true;
      settings = {
        user.name = "mutantmell";
        user.email = "malaguy@gmail.com";
      };
    };
  };

  system.stateVersion = "22.11";

}
