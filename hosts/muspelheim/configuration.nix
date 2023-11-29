{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./impermanence.nix
      ./microvm.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  common.zfs.enable = true;
  common.zfs.remoteUnlock.enable = true;

  boot.initrd.systemd.network = {
    netdevs."20-eno1.10" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.10";
      vlanConfig.Id = 10;
    };
    networks."20-eno1" = {
      matchConfig.Name = "eno1";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "eno1.10"
      ];
    };
    networks."20-eno1.10" = {
      matchConfig.Name = "eno1.10";
      networkConfig.DHCP = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
      networkConfig.Address = [ "10.0.10.31/24" ];
      routes = [ { routeConfig.Gateway = "10.0.10.1"; }];
    };
  };

  environment.systemPackages = [
    pkgs.git
  ];

  security.polkit.enable = true;

  networking = {
    hostName = "muspelheim";
    hostId = "518f0054";
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
    netdevs."20-eno1.10" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.10";
      vlanConfig.Id = 10;
    };
    netdevs."20-eno1.20" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.20";
      vlanConfig.Id = 20;
    };
    netdevs."20-eno1.100" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.100";
      vlanConfig.Id = 100;
    };
    networks."20-eno1" = {
      matchConfig.Name = "eno1";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "eno1.10"
        "eno1.20"
        "eno1.100"
      ];
    };
    networks."20-eno1.10" = {
      matchConfig.Name = "eno1.10";
      networkConfig.DHCP = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
      networkConfig.Address = [ "10.0.10.31/24" ];
      routes = [ { routeConfig.Gateway = "10.0.10.1"; }];
    };
    networks."20-vm20-bridge" = {
      matchConfig.Name = [ "eno1.20" "vm-20-*" ];
      networkConfig.Bridge = "br20";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-vm100-bridge" = {
      matchConfig.Name = [ "eno1.100" "vm-100-*" ];
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
  
  services.avahi = {
    enable = true;
    nssmdns = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  i18n.defaultLocale = "en_US.UTF-8";

  fileSystems."/mnt/data" = {
    device = "10.0.20.30:/data/data";
    fsType = "nfs";
  };
  fileSystems."/mnt/media" = {
    device = "10.0.20.30:/data/media/";
    fsType = "nfs";
  };

  common.openssh = {
    enable = true;
    users = [ "root" ];
    keys = [ "deploy" "home" ];
  };

  system.stateVersion = "22.11";
}
