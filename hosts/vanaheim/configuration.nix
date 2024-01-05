{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./impermanence.nix
    ./router.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  common.zfs.enable = true;
  # TODO: add remote unlock after no longer doing the router tests
  #common.zfs.remoteUnlock.enable = true;
  #common.zfs.remoteUnlock.hostkey = /persist/etc/ssh/initrd_ssh_host_ed25519_key;

  boot.extraModprobeConfig = "options kvm_intel nested=1";
  # boot.initrd.availableKernelModules = [ "e1000e" "8021q" ];
  # boot.initrd.systemd.network = {
  #   netdevs."20-enp88s0.10" = {
  #     netdevConfig.Kind = "vlan";
  #     netdevConfig.Name = "enp88s0.10";
  #     vlanConfig.Id = 10;
  #   };
  #   networks."20-enp88s0" = {
  #     matchConfig.Name = "enp88s0";
  #     networkConfig.DHCP = "no";
  #     networkConfig.LinkLocalAddressing = "no";
  #     vlan = [
  #       "enp88s0.10"
  #     ];
  #   };
  #   networks."20-enp88s0.10" = {
  #     matchConfig.Name = "enp88s0.10";
  #     networkConfig.DHCP = "no";
  #     networkConfig.IPv6PrivacyExtensions = "kernel";
  #     networkConfig.Address = [ "10.0.10.30/24" ];
  #     networkConfig.MulticastDNS = true;
  #     networkConfig.DNS = [ "10.0.10.1" ];
  #     routes = [ { routeConfig.Gateway = "10.0.10.1"; }];
  #   };
  # };

  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    MaxFileSec=7day
  '';

  environment.systemPackages = [
    pkgs.git
  ];
  security.polkit.enable = true;

  networking = {
    hostName = "vanaheim";
    hostId = "007f0200";
    useNetworkd = true;
    dhcpcd.enable = false;
  };

  # systemd.network = {
  #   enable = true;
  #   netdevs."20-br20" = {
  #     netdevConfig.Kind = "bridge";
  #     netdevConfig.Name = "br20";
  #   };
  #   netdevs."20-br100" = {
  #     netdevConfig.Kind = "bridge";
  #     netdevConfig.Name = "br100";
  #   };
  #   netdevs."20-enp88s0.10" = {
  #     netdevConfig.Kind = "vlan";
  #     netdevConfig.Name = "enp88s0.10";
  #     vlanConfig.Id = 10;
  #   };
  #   netdevs."20-enp88s0.20" = {
  #     netdevConfig.Kind = "vlan";
  #     netdevConfig.Name = "enp88s0.20";
  #     vlanConfig.Id = 20;
  #   };
  #   netdevs."20-enp88s0.100" = {
  #     netdevConfig.Kind = "vlan";
  #     netdevConfig.Name = "enp88s0.100";
  #     vlanConfig.Id = 100;
  #   };
  #   networks."20-enp88s0" = {
  #     matchConfig.Name = "enp88s0";
  #     networkConfig.DHCP = "no";
  #     networkConfig.LinkLocalAddressing = "no";
  #     vlan = [
  #       "enp88s0.10"
  #       "enp88s0.20"
  #       "enp88s0.100"
  #     ];
  #   };
  #   networks."20-enp88s0.10" = {
  #     matchConfig.Name = "enp88s0.10";
  #     networkConfig.DHCP = "no";
  #     networkConfig.IPv6PrivacyExtensions = "kernel";
  #     networkConfig.Address = [ "10.0.10.30/24" ];
  #     networkConfig.MulticastDNS = true;
  #     routes = [ { routeConfig.Gateway = "10.0.10.1"; }];
  #   };
  #   networks."20-vm20-bridge" = {
  #     matchConfig.Name = [ "enp88s0.20" "vm-20-*" ];
  #     networkConfig.Bridge = "br20";
  #     networkConfig.DHCP = "no";
  #     networkConfig.LinkLocalAddressing = "no";
  #     networkConfig.IPv6PrivacyExtensions = "kernel";
  #   };
  #   networks."20-vm100-bridge" = {
  #     matchConfig.Name = [ "enp88s0.100" "vm-100-*" ];
  #     networkConfig.Bridge = "br100";
  #     networkConfig.DHCP = "no";
  #     networkConfig.LinkLocalAddressing = "no";
  #     networkConfig.IPv6PrivacyExtensions = "kernel";
  #   };
  #   networks."20-br20" = {
  #     matchConfig.Name = "br20";
  #     networkConfig.DHCP = "no";
  #     networkConfig.LinkLocalAddressing = "no";
  #     networkConfig.IPv6PrivacyExtensions = "kernel";
  #   };
  #   networks."20-br100" = {
  #     matchConfig.Name = "br100";
  #     networkConfig.DHCP = "no";
  #     networkConfig.LinkLocalAddressing = "no";
  #     networkConfig.IPv6PrivacyExtensions = "kernel";
  #   };
  # };
  # services.resolved.enable = true;
  i18n.defaultLocale = "en_US.UTF-8";

  # fileSystems."/mnt/data" = {
  #   device = "10.0.10.32:/data/data";
  #   fsType = "nfs";
  # };
  # fileSystems."/mnt/media" = {
  #   device = "10.0.10.32:/data/media/";
  #   fsType = "nfs";
  # };

  common.openssh = {
    enable = true;
    users = [ "root" ];
    keys = [ "deploy" "home" ];
  };

  home-manager.users.root = {
    home.stateVersion = "23.11";
    programs.git = {
      enable = true;
      userName = "mutantmell";
      userEmail = "malaguy@gmail.com";
      extraConfig.core.sshCommand = "ssh -i /etc/ssh/ssh_host_ed25519_key";
    };
  };

  system.stateVersion = "23.11";
}
