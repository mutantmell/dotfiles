{ config, pkgs, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./hardware-configuration.nix
    ./impermanence.nix
    # ./router.nix
    ./microvm.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  common.zfs.enable = true;
  # TODO: add remote unlock after no longer doing the router tests
  common.zfs.remoteUnlock.enable = true;
  common.zfs.remoteUnlock.hostkey = /persist/etc/ssh/initrd_ssh_host_ed25519_key;

  boot.extraModprobeConfig = "options kvm_intel nested=1";
  # todo: add after creating an initrd host key
  boot.initrd.availableKernelModules = [ "e1000e" "8021q" ];
  boot.initrd.systemd.network = {
    netdevs."20-enp88s0.10" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp88s0.10";
      vlanConfig.Id = 10;
    };
    networks."20-enp88s0" = {
      matchConfig.Name = "enp88s0";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "enp88s0.10"
      ];
    };
    networks."20-enp88s0.10" = {
      matchConfig.Name = "enp88s0.10";
      networkConfig.DHCP = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
      networkConfig.Address = [ "10.0.10.30/24" ];
      networkConfig.MulticastDNS = true;
      networkConfig.DNS = [ "10.0.10.1" ];
      routes = [ { Gateway = "10.0.10.1"; }];
    };
  };

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

  # todo: remove, set mutableUsers = false, etc
  users.users.root.hashedPassword = "$y$j9T$3LKptm/9A.x8WAyU6mGNx.$k8yOrBlbgPl2J0cUcAX1GZVNuWQHl0f.4xZNiIlaKy9";

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
