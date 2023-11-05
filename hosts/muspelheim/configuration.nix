{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./microvm.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  environment.systemPackages = with pkgs; [
    virt-manager
    vim
    git
  ];

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      ovmf.enable = true;
      runAsRoot = false;
    };
    onBoot = "start";
    onShutdown = "suspend";
    allowedBridges = [ "br20" "br100" ];
  };
  security.polkit.enable = true;

  systemd.network = {
    enable = true;
    netdevs."10-eno1.10" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.10";
      vlanConfig.Id = 10;
    };
    netdevs."10-eno1.20" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.20";
      vlanConfig.Id = 20;
    };
    netdevs."10-eno1.100" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.100";
      vlanConfig.Id = 100;
    };

    netdevs."11-br20" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br20";
    };
    netdevs."11-br100" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br100";
    };

    networks."20-eno1" = {
      matchConfig.Name = "eno1";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "eno1.10"
        "eno1.20"
        "eno1.100"
      ];
    };

    networks."21-eno1.10" = {
      matchConfig.Name = "eno1.10";
      networkConfig.Address = [ "10.0.10.31/24" ];
      networkConfig.Gateway = "10.0.10.1";
      networkConfig.DNS = [ "10.0.10.1" ];
      linkConfig.RequiredForOnline = "routable";
    };

    networks."21-br20" = {
      matchConfig.Name = ["eno1.20" "vm-20-*"];
      networkConfig.Bridge = "br20";
    };
    networks."21-br100" = {
      matchConfig.Name = ["eno1.100" "vm-100-*"];
      networkConfig.Bridge = "br100";
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

  users.users."qemu-agent" = {
    isNormalUser = true;
    extraGroups = [ "libvirtd" ];
  };

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
    users = [ "root" "qemu-agent" ];
    keys = [ "deploy" "home" ];
  };

  system.stateVersion = "22.11";
}
