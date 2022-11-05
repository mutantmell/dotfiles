{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      #./nas.nix
    ];

  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.device = "/dev/sda";

  networking.hostName = "jotunheimr";
  time.timeZone = "America/Los_Angeles";

  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };

  networking.useDHCP = false;
  networking.interfaces.enp4s0 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "10.0.20.30";
      prefixLength = 24;
    }];
  };
  networking.defaultGateway = "10.0.20.1";
  networking.nameservers = [ "10.0.20.1" ];

  environment.systemPackages = with pkgs; [
    vim
    wget
  ];

  services.openssh = {
    enable = true;
    passwordAuthentication = false;
    permitRootLogin = "prohibit-password";
    kbdInteractiveAuthentication = false;
  };

#  users.mutableUsers = false;
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
  ];

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
      userServices = true;
      workstation = true;
    };
  };

  boot.zfs.extraPools = [ "data" ];
  services.zfs.autoScrub.enable = true;
  
  system.stateVersion = "21.11";

}
