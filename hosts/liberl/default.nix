{
  config,
  pkgs,
  lib,
  ...
}: let
  hostname = "liberl";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./hardware-configuration.nix
    (import ../../profiles/disko/btrfs.nix {
      disk = "/dev/disk/by-id/ata-Samsung_SSD_860_EVO_250GB_S59WNJ0MC27735B";
      l2arcSize = "32G";
      inherit lib;
    })
    ./impermanence.nix
    ./sops.nix
    ./nas.nix
    ./monit.nix
    ./wg-ba.nix
    ./microvm
  ];

  common.impermanence.enable = true;
  common.btrfs.enable = true;
  common.btrfs.keyfileUnlock.enable = true;
  common.btrfs.impermanence.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.extraPools = ["data"];
  boot.zfs.forceImportRoot = false;

  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;
  services.smartd.enable = true;

  services.timesyncd.enable = true;
  time.timeZone = "UTC";

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
    pkgs.wget
    pkgs.tmux
    pkgs.htop
  ];

  networking = {
    hostName = hostname;
    hostId = "9f034bc8";
    useDHCP = false;
    useNetworkd = true;
    dhcpcd.enable = false;
  };

  systemd.network = {
    enable = true;
    netdevs."20-br20" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br20";
    };
    netdevs."20-br21" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br21";
    };
    netdevs."20-br50" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br50";
    };
    netdevs."20-br100" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br100";
    };
    netdevs."20-enp4s0.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp4s0.11";
      vlanConfig.Id = 11;
    };
    netdevs."20-enp4s0.20" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp4s0.20";
      vlanConfig.Id = 20;
    };
    netdevs."20-enp4s0.21" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp4s0.21";
      vlanConfig.Id = 21;
    };
    netdevs."20-enp4s0.50" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp4s0.50";
      vlanConfig.Id = 50;
    };
    netdevs."20-enp4s0.100" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp4s0.100";
      vlanConfig.Id = 100;
    };
    networks."20-enp4s0" = {
      matchConfig.Name = "enp4s0";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "enp4s0.11"
        "enp4s0.20"
        "enp4s0.21"
        "enp4s0.50"
        "enp4s0.100"
      ];
    };
    networks."20-enp4s0.11" = {
      matchConfig.Name = "enp4s0.11";
      networkConfig.DHCP = "no";
      networkConfig.IPv6AcceptRA = true;
      networkConfig.IPv6PrivacyExtensions = "yes";
      networkConfig.Address = [host.cidr4 host.cidr6];
      networkConfig.MulticastDNS = true;
      networkConfig.LLMNR = true;
      networkConfig.DNS = [zone.gateway4 zone.gateway6];
      networkConfig.Domains = ["internal"];
      routes = [
        {Gateway = zone.gateway4;}
        {
          Destination = "fdc6:55f2:0a5e::/48";
          Gateway = zone.gateway6;
        }
      ];
    };
    networks."20-vm20-bridge" = {
      matchConfig.Name = ["enp4s0.20" "vm-20-*"];
      networkConfig.Bridge = "br20";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-vm21-bridge" = {
      matchConfig.Name = ["enp4s0.21" "vm-21-*"];
      networkConfig.Bridge = "br21";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-vm50-bridge" = {
      matchConfig.Name = ["enp4s0.50" "vm-50-*"];
      networkConfig.Bridge = "br50";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-vm100-bridge" = {
      matchConfig.Name = ["enp4s0.100" "vm-100-*"];
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
    networks."20-br21" = {
      matchConfig.Name = "br21";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br50" = {
      matchConfig.Name = "br50";
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

  # Host-based input firewall
  networking.firewall = {
    enable = true;
    extraInputRules = ''
      # SSH from router + vHOME, drop all else
      ip saddr { ${zone.gateway4}, ${net.networks.trusted.subnet4} } tcp dport 22 accept
      ip6 saddr { ${zone.gateway6}, ${net.networks.trusted.subnet6} } tcp dport 22 accept
      tcp dport 22 drop
    '';
  };

  common.internal-pki.enable = true;

  fluent-bit-agent = {
    enable = true;
    extraInputs = [
      {
        name = "prometheus_scrape";
        tag = "host.metric.zfs";
        host = "127.0.0.1";
        port = 9002;
        scrape_interval = "60";
      }
      {
        name = "prometheus_scrape";
        tag = "host.metric.smartctl";
        host = "127.0.0.1";
        port = 9003;
        scrape_interval = "60";
      }
    ];
  };
  node-exporter-client.enable = true;

  services.avahi.enable = true;
  services.avahi.publish.enable = true;
  services.avahi.publish.addresses = true;

  common.openssh = {
    enable = true;
    keys = ["deploy" "home" "edith"];
  };

  users.users.mutantmell = {
    isNormalUser = true;
    description = "samba client user";
    group = "mutantmell";
    extraGroups = ["media"];
  };
  users.groups.mutantmell = {};

  home-manager.backupFileExtension = "bak";
  home-manager.users.root = {
    home.stateVersion = "23.11";
    programs.git = {
      enable = true;
      settings = {
        user.name = "mutantmell";
        user.email = "malaguy@gmail.com";
      };
    };
  };

  system.stateVersion = "25.11";
}
