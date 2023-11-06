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

  networking = let lan = "eno1"; in {
    hostName = "muspelheim";
    #useNetworkd = true;
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
      "${lan}".useDHCP = false;
    };
    defaultGateway.address = "10.0.10.1";
    defaultGateway.interface = "${lan}.10";
    nameservers = [ "10.0.10.1" ];
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
