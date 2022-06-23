{ config, pkgs, lib, nixos-hardware, ... }:

{
  imports = [ nixos-hardware.nixosModules.raspberry-pi-4 ];

  nixpkgs.config.allowUnfree = true;

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };

  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.allowedTCPPorts = [ 
    53    # DNS
    8443  # Unifi
  ];

  networking.hostName = "alfheim";
#  networking.useDHCP = false;
  networking.interfaces.eth0 = {
#    useDHCP = false;
    ipv4.addresses = [{
      address = "10.0.10.2";
      prefixLength = 24;
    }];
  };
  networking.defaultGateway = "10.0.10.1";
  networking.nameservers = [ "10.0.10.1" ];

  services.openssh = {
    enable = true;
    passwordAuthentication = false;
    permitRootLogin = "prohibit-password";
    kbdInteractiveAuthentication = false;
  };
  
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

  services.unifi = {
    enable = true;
    openFirewall = true;
  };
#  networking.firewall.allowedTCPPorts = [ 8443 ];

  # gpu accelleration
  #hardware.raspberry-pi."4".fkms-3d.enable = true;
  hardware.raspberry-pi."4".poe-hat.enable = true;

  system.stateVersion = "22.11";
}
