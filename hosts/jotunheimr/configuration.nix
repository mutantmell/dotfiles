{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./nas.nix
      ./monit.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.extraPools = [ "data" ];

  services.zfs.autoScrub.enable = true;
  services.smartd.enable = true;

  networking.hostName = "jotunheimr";
  networking.hostId = "9f034bc8";

  services.ntp.enable = true;
  time.timeZone = "UTC";

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
    wget
    smartmontools
    jdupes
    ncdu
    tmux
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      KbdInteractiveAuthentication = false;
    };
  };

  #  users.mutableUsers = false;
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
  ];
  users.users.mjollnir = {
    isNormalUser = true;
    description = "samba client user";
    group = "mjollnir";
  };
  users.groups.mjollnir = {};

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  power.ups = {
    # TODO: use the updated service once this pr is merged: https://github.com/NixOS/nixpkgs/pull/213006
    #enable = true;
    ups."apc" = {
      driver = "usbhid-ups";
      port = "auto";
      description = "APC UPS";
    };
  };
  
  system.stateVersion = "22.11";

}
