{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  environment.systemPackages = with pkgs; [
    bind
  ];

  networking.hostName = "heimdall"; # Define your hostname.
  networking.useDHCP = false;
  networking.interfaces.enp1s0.useDHCP = true;
#  networking.interfaces.enp1s0 = {
#    useDHCP = false;
#    ipv4.addresses = [{
#      address = "10.0.10.3";
#      prefixLength = 24;
#    }];
#  };
#  networking.defaultGateway = "10.0.10.1";

  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.allowedTCPPorts = [ 53 ];

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
      userServices = true;
    };
  };

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";
  services.openssh.settings.PasswordAuthentication = false;

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPoCCiFtZ//7igTH9ChEXLkUsA35xzX33ZkhPY0KOohO malaguy@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
  ];

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

  system.stateVersion = "22.05"; # Did you read the comment?

}

