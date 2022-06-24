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
  networking.useDHCP = false;
  networking.interfaces.eth0 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "10.0.10.2";
      prefixLength = 24;
    }];
  };
  networking.defaultGateway = "10.0.10.1";

  environment.systemPackages = with pkgs; [
    bind
  ];

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


  services.adguardhome = {
    enable = true;
    openFirewall = true;
    settings = {
      dns = {
        bind_host = "0.0.0.0";
        bind_hosts = [ "127.0.0.1" "0.0.0.0" ];
        upstream_dns = [ "127.0.0.1:5335" ];
        bootstrap_dns = [ "127.0.0.1:5335" ];
        allowed_clients = [ "127.0.0.1" "10.0.10.3" "10.0.10.1" ];
      };
      dhcp = {
        enabled = false;
        gateway_ip = "10.0.10.1";
        subnet_mask = "255.255.255.0";
        range_start = "10.0.10.100";
        range_end = "10.0.10.200";
        lease_duration = 0;
        icmp_timeout_msec = 0;
      };
    };
  };

  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = [ "127.0.0.1" ];
        port = 5335;
        access-control = [
          "0.0.0.0/0 refuse"
          "127.0.0.0/8 allow"
          "::1 allow"
        ];
        aggressive-nsec = true;
        local-zone = ''"local." static'';
        local-data = [
          ''"local. A 10.0.10.1"''
          ''"local. AAAA fd00::1"''
          ''"yggdrasil.local. A 10.0.10.1"''
          ''"yggdrasil.local. AAAA fd00::1"''
          ''"heimdall.local. A 10.0.10.3"''
          ''"heimdall.local. AAAA fd00::2"''
        ];
      };
      remote-control.control-enable = true;
    };
  };

  # gpu accelleration
  #hardware.raspberry-pi."4".fkms-3d.enable = true;
  hardware.raspberry-pi."4".poe-hat.enable = true;

  system.stateVersion = "22.11";
}
