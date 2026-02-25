{ config, pkgs, ... }:

let
  hostname = "erebonia";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
  nas = net.hosts.remiferia;
in {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./hardware-configuration.nix
    ./impermanence.nix
    ./microvm.nix
    ./incus.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  common.zfs.enable = true;
  common.zfs.remoteUnlock.enable = true;
  common.zfs.remoteUnlock.hostkey = /persist/etc/ssh/initrd_ssh_host_ed25519_key;

  boot.extraModprobeConfig = "options kvm_intel nested=1";
  boot.initrd.availableKernelModules = [ "e1000e" "8021q" ];
  boot.initrd.systemd.network = {
    netdevs."20-eno1.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.11";
      vlanConfig.Id = 11;
    };
    networks."20-eno1" = {
      matchConfig.Name = "eno1";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "eno1.11"
      ];
    };
    networks."20-eno1.11" = {
      matchConfig.Name = "eno1.11";
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
    hostId = "518f0054";
    useNetworkd = true;
    useDHCP = false;
    dhcpcd.enable = false;
  };

  systemd.network = {
    enable = true;
    netdevs."20-br11" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br11";
    };
    netdevs."20-br20" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br20";
    };
    netdevs."20-br100" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br100";
    };
    netdevs."20-eno1.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.11";
      vlanConfig.Id = 11;
    };
    netdevs."20-eno1.20" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.20";
      vlanConfig.Id = 20;
    };
    netdevs."20-eno1.100" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.100";
      vlanConfig.Id = 100;
    };
    networks."20-eno1" = {
      matchConfig.Name = "eno1";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "eno1.11"
        "eno1.20"
        "eno1.100"
      ];
    };
    networks."20-vm11-bridge" = {
      matchConfig.Name = [ "eno1.11" "vm-11-*" ];
      networkConfig.Bridge = "br11";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br11" = {
      matchConfig.Name = "br11";
      networkConfig.DHCP = "no";
      networkConfig.IPv6AcceptRA = false;
      networkConfig.Address = [ host.cidr4 host.cidr4Legacy host.cidr6 ];
      networkConfig.MulticastDNS = true;
      routes = [
        { Gateway = zone.gateway4; }
        { Gateway = zone.gateway6; }
      ];
    };
    networks."20-vm20-bridge" = {
      matchConfig.Name = [ "eno1.20" "vm-20-*" ];
      networkConfig.Bridge = "br20";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-vm100-bridge" = {
      matchConfig.Name = [ "eno1.100" "vm-100-*" ];
      networkConfig.Bridge = "br100";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br20" = {
      matchConfig.Name = "br20";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br100" = {
      matchConfig.Name = "br100";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
  };
  services.resolved.enable = true;

  # Host-based input firewall: restrict SSH to router + vHOME
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 9100 ];
    extraInputRules = ''
      ip saddr { ${zone.gateway4}, ${zone.gateway4Legacy}, ${net.networks.trusted.subnet4}, ${net.networks.trusted.subnet4Legacy} } tcp dport 22 accept
      ip6 saddr { ${zone.gateway6}, ${net.networks.trusted.subnet6} } tcp dport 22 accept
      tcp dport 22 drop
    '';
  };

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [ "systemd" ];
    port = 9100;
  };

  i18n.defaultLocale = "en_US.UTF-8";

  fileSystems."/mnt/data" = {
    device = "${nas.ipv4}:/data/data";
    fsType = "nfs";
  };
  fileSystems."/mnt/media" = {
    device = "${nas.ipv4}:/data/media/";
    fsType = "nfs";
  };

  common.openssh = {
    enable = true;
    users = [ "root" ];
    keys = [ "deploy" "home" ];
  };

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
