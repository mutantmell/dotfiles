{ config, pkgs, ... }:

let
  hostname = "calvard";
  inherit (pkgs.mmell.lib.data.network.forHost hostname) host zone;
in {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./hardware-configuration.nix
    (import ../../profiles/disko/vm-host.nix { disk = "/dev/nvme0n1"; })
    ./impermanence.nix
    ./microvm
    ./incus
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
    netdevs."20-enp88s0.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp88s0.11";
      vlanConfig.Id = 11;
    };
    networks."20-enp88s0" = {
      matchConfig.Name = "enp88s0";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "enp88s0.11"
      ];
    };
    networks."20-enp88s0.11" = {
      matchConfig.Name = "enp88s0.11";
      networkConfig.DHCP = "no";
      networkConfig.IPv6AcceptRA = false;
      networkConfig.Address = [ host.cidr4 host.cidr4Legacy host.cidr6 ];
      networkConfig.MulticastDNS = true;
      networkConfig.DNS = [ zone.gateway4 zone.gateway4Legacy zone.gateway6 ];
      routes = [
        { Gateway = zone.gateway4; }
        { Gateway = zone.gateway6; }
      ];
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
    hostName = hostname;
    hostId = "007f0200";
    useNetworkd = true;
    dhcpcd.enable = false;
  };

  networking.firewall.allowedTCPPorts = [ 9100 ];

  promtail-client.enable = true;

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [ "systemd" ];
    port = 9100;
  };

  i18n.defaultLocale = "en_US.UTF-8";

  common.openssh = {
    enable = true;
    users = [ "root" ];
    keys = [ "deploy" "home" ];
  };

  programs.ssh.extraConfig = ''
    Host messeldam
      Hostname 10.97.20.42
      User root
      IdentityFile /etc/ssh/ssh_host_ed25519_key
      IdentitiesOnly yes
  '';

  users.mutableUsers = false;

  home-manager.users.root = {
    home.stateVersion = "25.11";
    programs.git = {
      enable = true;
      settings = {
        user.name = "mutantmell";
        user.email = "malaguy@gmail.com";
        core.sshCommand = "ssh -i /etc/ssh/ssh_host_ed25519_key";
      };
    };
  };

  system.stateVersion = "25.11";
}
