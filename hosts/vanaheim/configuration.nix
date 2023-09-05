{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.extraModprobeConfig = "options kvm_intel nested=1";

  environment.systemPackages = with pkgs; [
    virtmanager
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

  networking = let lan = "enp88s0"; in {
    hostName = "vanaheim";
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
          address = "10.0.10.30";
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

  users.users = let
    keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
    ];
  in {
    root.openssh.authorizedKeys.keys = keys;
    "qemu-agent" = {
      isNormalUser = true;
      extraGroups = [ "libvirtd" ];
      openssh.authorizedKeys.keys = keys;
    };
  };

  fileSystems."/mnt/data" = {
    device = "10.0.20.30:/data/data";
    fsType = "nfs";
  };
  fileSystems."/mnt/media" = {
    device = "10.0.20.30:/data/media/";
    fsType = "nfs";
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      KbdInteractiveAuthentication = false;
    };
  };

  system.stateVersion = "22.11";
}
