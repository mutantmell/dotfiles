{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./impermanence.nix
      ./sops.nix
      ./microvm.nix
    ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  networking.hostName = "yggdrasil";
  time.timeZone = "America/Los_Angeles";

  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    batctl
    git
    wireguard-tools
  ];

  common.openssh = {
    enable = true;
    keys = [ "deploy" "home" ];
  };

  router6 = {
    enable = true;

    # ULA prefix for internal IPv6 addressing
    # IPv6 addresses auto-generated from VLAN tags (e.g., VLAN 10 -> fdc6:55f2:0a5e:a::1/64)
    ulaPrefix = "fdc6:55f2:0a5e::/48";

    dns = {
      upstream = [ "10.0.10.2" ];  # alfheim microVM (primary - has local hostnames)
      useDHCPFallback = true;      # fall back to ISP DNS when alfheim microVM is down
      localDomain = "local";
    };

    firewall = {
      # Forward from DMZ to wg-ba
      extraForwardRules = ''
        iifname "vDMZ.lan" oifname "wg-ba" accept
        iifname "wg-ba" ip daddr 10.0.100.40 accept
      '';

      # Port forward SSH from wg-ba to surtr
      portForwards = [
        {
          proto = "tcp";
          sourcePort = 22;
          destination = "10.0.100.40:22";
          sourceInterface = "wg-ba";
        }
      ];

      extraNatRules = ''
        oifname "wg-ba" masquerade
        iifname "wg-ba" ip daddr 10.0.100.40 masquerade
      '';
    };

    topology = {
      # WAN interface - DHCP from ISP
      wan = {
        mac = "00:e0:67:1b:70:34";
        network = {
          type = "dhcp";
          trust = "external";
          nat.enable = true;
          defaultRoute = true;
        };
      };

      # LAN interface - bonded with opt1
      lan = {
        mac = "00:e0:67:1b:70:35";
        bondDevice = "bond0";
        network = {
          type = "disabled";
          required = false;
        };
      };

      # Second LAN interface - bonded with lan
      opt1 = {
        mac = "00:e0:67:1b:70:36";
        bondDevice = "bond0";
        network = {
          type = "disabled";
          required = false;
        };
      };

      # Batman-adv mesh device
      bat0 = {
        batman = {
          gatewayMode = "off";
          routingAlgorithm = "batman-v";
        };
        network = {
          type = "disabled";
          required = false;
        };
        vlans = {
          # Bridged VLANs - network config is on the bridge
          "vMGMT.bat0" = { tag = 10; bridge = "brMGMT"; };
          "vHOME.bat0" = { tag = 20; bridge = "brHOME"; };

          # Batman-only VLANs (no physical counterpart)
          "vGUEST.bat0" = {
            tag = 30;  # -> fdc6:55f2:0a5e:1e::1/64
            network = {
              type = "static";
              addresses = [ "10.0.30.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };
          "vIOT.bat0" = {
            tag = 40;  # -> fdc6:55f2:0a5e:28::1/64
            network = {
              type = "static";
              addresses = [ "10.0.40.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };
          "vGAME.bat0" = {
            tag = 41;  # -> fdc6:55f2:0a5e:29::1/64
            network = {
              type = "static";
              addresses = [ "10.0.41.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };
        };
      };

      # Spare interface
      opt2 = {
        mac = "00:e0:67:1b:70:37";
        network = {
          type = "disabled";
          required = false;
        };
      };

      # Wireguard - BA tunnel (isolated/lockdown)
      "wg-ba" = {
        network = {
          type = "static";
          addresses = [
            "10.100.0.1/24"
            "fdc6:55f2:0a5e:6400::1/64"  # Manual IPv6 for WG
          ];
          trust = "isolated";
          required = false;
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-ba-privatekey".path;
          port = 38506;
          openFirewall = true;
          peers = [{
            publicKey = "O+WWPlhy6Lg9YT3hYqq+/8gZ48PpRXaUTl4eFFwgTVA=";
            allowedIPs = [ "10.100.0.3/32" "fdc6:55f2:0a5e:6400::3/128" ];
            persistentKeepalive = 25;
          }];
        };
      };

      # Wireguard - VPN for mobile devices
      "wg-vpn" = {
        network = {
          type = "static";
          addresses = [
            "10.100.10.1/24"
            "fdc6:55f2:0a5e:640a::1/64"  # Manual IPv6 for WG
          ];
          trust = "trusted";
          required = false;
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-vpn-privatekey".path;
          port = 59362;
          openFirewall = true;
          peers = [
            {
              publicKey = "sqPuQAWAKJzTice+L2kedo9X7Hx5WsMT/A6QXJVL/nA=";
              allowedIPs = [ "10.100.10.20/32" "fdc6:55f2:0a5e:640a::14/128" ];
            }
            {
              publicKey = "8g4r9czA23tS/XTOajuIa/BNfDE2x4GwdXXi+udE6gY=";
              allowedIPs = [ "10.100.10.21/32" "fdc6:55f2:0a5e:640a::15/128" ];
            }
          ];
        };
      };

      # Wireguard - External tunnel to matrix server
      "wg-mx" = {
        network = {
          type = "static";
          addresses = [
            "10.100.20.1/24"
            "fdc6:55f2:0a5e:6414::1/64"  # Manual IPv6 for WG
          ];
          trust = "external";
          required = false;
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-mx-privatekey".path;
          port = 53973;
          peers = [{
            publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
            allowedIPs = [ "10.100.20.10/32" "fdc6:55f2:0a5e:6414::a/128" ];
            endpoint = "helveticastandard.com:58156";
            persistentKeepalive = 25;
          }];
        };
      };
    };

    # Bridges combining physical and batman VLANs into unified networks
    bridges = {
      brMGMT = {
        vlanTag = 10;  # -> fdc6:55f2:0a5e:a::1/64
        network = {
          type = "static";
          addresses = [ "10.0.10.1/24" ];
          trust = "management";
          dhcp.enable = true;
          dhcp6.enable = true;
        };
      };
      brHOME = {
        vlanTag = 20;  # -> fdc6:55f2:0a5e:14::1/64
        network = {
          type = "static";
          addresses = [ "10.0.20.1/24" ];
          trust = "trusted";
          dhcp.enable = true;
          dhcp6.enable = true;
        };
      };
    };

    # Bond combining lan + opt1 for increased bandwidth (LACP)
    bonds = {
      bond0 = {
        mode = "802.3ad";
        lacpTransmitRate = "fast";
        miiMonitorSec = "100ms";
        batmanDevice = "bat0";
        network = {
          type = "disabled";
          mtu = 1536;
          required = false;
        };
        vlans = {
          # Bridged VLANs - network config is on the bridge
          "vMGMT.bond0" = { tag = 10; bridge = "brMGMT"; };
          "vHOME.bond0" = { tag = 20; bridge = "brHOME"; };

          # Bond-only VLANs (no batman counterpart needed now)
          "vADU.bond0" = {
            tag = 31;  # -> fdc6:55f2:0a5e:1f::1/64
            network = {
              type = "static";
              addresses = [ "10.0.31.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };
          "vDMZ.bond0" = {
            tag = 100;  # -> fdc6:55f2:0a5e:64::1/64
            network = {
              type = "static";
              addresses = [ "10.0.100.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };
        };
      };
    };
  };

  # Bridge microVM tap interfaces into the management network
  # The vm-10-alfheim tap interface is created by microvm and needs to be bridged to brMGMT
  systemd.network.networks."10-vm-mgmt" = {
    matchConfig.Name = "vm-10-*";
    networkConfig = {
      Bridge = "brMGMT";
      DHCP = "no";
      LinkLocalAddressing = "no";
    };
    linkConfig.RequiredForOnline = "no";
  };

  networking.extraHosts = ''
    10.0.10.1 yggdrasil
    10.0.10.1 yggdrasil.local
    10.0.10.2 alfheim
    10.0.10.2 alfheim.local
    10.0.20.30 gridr.local
    10.0.100.40 surtr.local
    10.0.100.50 bragi.local
    10.0.100.51 njord.local
  '';

  # Persistence for router state
  environment.persistence."/persist".directories = [
    "/var/lib/kea"
    "/var/lib/knot-resolver"
  ];

  home-manager.users.root = {
    home.stateVersion = "23.11";
    programs.git = {
      enable = true;
      userName = "mutantmell";
      userEmail = "malaguy@gmail.com";
      extraConfig.core.sshCommand = "ssh -i /etc/ssh/ssh_host_ed25519_key";
    };
  };

  system.stateVersion = "24.05";

}
