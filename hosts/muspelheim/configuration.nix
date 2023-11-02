{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
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

  # TODO: convert to networkD, and use common networking for base config
  networking = let lan = "eno1"; in {
    hostName = "muspelheim";
    dhcpcd.enable = false;

    vlans = {
      "${lan}.10" = { id = 10; interface = lan; };
      "${lan}.20" = { id = 20; interface = lan; };
      "${lan}.100" = { id = 100; interface = lan; };
    };

    bridges = {
      "br20".interfaces = [ "${lan}.20" ];
      "br100".interfaces = [ "${lan}.100" ];
    };

    interfaces = {
      "${lan}.10" = {
        useDHCP = false;
        ipv4.addresses = [{
          address = "10.0.10.31";
          prefixLength = 24;
        }];
      };
    };
    defaultGateway = "10.0.10.1";
    nameservers = [ "10.0.10.1" ];
  };

  services.avahi = {
    enable = true;
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
