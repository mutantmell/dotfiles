{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./impermanence.nix
      ./sops.nix
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

    dns = {
      upstream = [ "10.0.10.2" ];           # alfheim (primary - has local hostnames)
      fallback = [ "1.1.1.1" "8.8.8.8" ];   # public DNS (fallback when alfheim is down)
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

      # LAN interface with VLANs
      lan = {
        mac = "00:e0:67:1b:70:35";
        batmanDevice = "bat0";
        network = {
          type = "disabled";
          required = false;
          mtu = 1536;
        };
        vlans = {
          "vMGMT.lan" = {
            tag = 10;
            network = {
              type = "static";
              addresses = [ "10.0.10.1/24" ];
              trust = "management";
              dhcp.enable = true;
            };
          };
          "vHOME.lan" = {
            tag = 20;
            network = {
              type = "static";
              addresses = [ "10.0.20.1/24" ];
              trust = "trusted";
              dhcp.enable = true;
            };
          };
          "vADU.lan" = {
            tag = 31;
            network = {
              type = "static";
              addresses = [ "10.0.31.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
            };
          };
          "vDMZ.lan" = {
            tag = 100;
            network = {
              type = "static";
              addresses = [ "10.0.100.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
            };
          };
        };
      };

      # Spare interface
      opt1 = {
        mac = "00:e0:67:1b:70:36";
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
          "vMGMT.bat0" = {
            tag = 10;
            network = {
              type = "static";
              addresses = [ "10.1.10.1/24" ];
              trust = "management";
              dhcp.enable = true;
            };
          };
          "vHOME.bat0" = {
            tag = 20;
            network = {
              type = "static";
              addresses = [ "10.1.20.1/24" ];
              trust = "trusted";
              dhcp.enable = true;
            };
          };
          "vGUEST.bat0" = {
            tag = 30;
            network = {
              type = "static";
              addresses = [ "10.1.30.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
            };
          };
          "vIOT.bat0" = {
            tag = 40;
            network = {
              type = "static";
              addresses = [ "10.1.40.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
            };
          };
          "vGAME.bat0" = {
            tag = 41;
            network = {
              type = "static";
              addresses = [ "10.1.41.1/24" ];
              trust = "untrusted";
              dhcp.enable = true;
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
          addresses = [ "10.100.0.1/24" ];
          trust = "isolated";
          required = false;
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-ba-privatekey".path;
          port = 38506;
          openFirewall = true;
          peers = [{
            publicKey = "O+WWPlhy6Lg9YT3hYqq+/8gZ48PpRXaUTl4eFFwgTVA=";
            allowedIPs = [ "10.100.0.3/32" ];
            persistentKeepalive = 25;
          }];
        };
      };

      # Wireguard - VPN for mobile devices
      "wg-vpn" = {
        network = {
          type = "static";
          addresses = [ "10.100.10.1/24" ];
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
              allowedIPs = [ "10.100.10.20/32" ];
            }
            {
              publicKey = "8g4r9czA23tS/XTOajuIa/BNfDE2x4GwdXXi+udE6gY=";
              allowedIPs = [ "10.100.10.21/32" ];
            }
          ];
        };
      };

      # Wireguard - External tunnel to matrix server
      "wg-mx" = {
        network = {
          type = "static";
          addresses = [ "10.100.20.1/24" ];
          trust = "external";
          required = false;
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-mx-privatekey".path;
          port = 53973;
          peers = [{
            publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
            allowedIPs = [ "10.100.20.10/32" ];
            endpoint = "helveticastandard.com:58156";
            persistentKeepalive = 25;
          }];
        };
      };
    };
  };

  networking.extraHosts = ''
    10.0.10.1 yggdrasil
    10.0.10.1 yggdrasil.local
    10.0.10.2 alfheim
    10.0.10.2 alfheim.local
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
