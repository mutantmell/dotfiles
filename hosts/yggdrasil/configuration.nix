{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
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

  router = {
    enable = true;
    dns.upstream = "10.0.10.2";
    dns.dyndns = {
      enable = true;
      protocol = "namecheap";
      server = "https://dynamicdns.park-your-domain.com";
      usernameFile = config.sops.secrets."dyndns-host-domain".path;
      passwordFile = config.sops.secrets."dyndns-host-password".path;
      hosts = [ "home" ];
      renewPeriod = "60m";
    };
    firewall.extraForwards = [
      {
        ip.saddr = "10.0.20.30";
        ip.daddr = "10.100.0.3";
        verdict = "accept";
      }
      {
        iifname = [
          "vDMZ.lan"
        ];
        oifname = "wg-ba";
        verdict = "accept";
      }
      {
        iifname = "wg-ba";
        ip.daddr = "10.0.100.40";
        verdict = "accept";
      }
    ];
    firewall.extraPreRoutes = [
      {
        iifname = "wg-ba";
        tcp.dport = "22";
        verdict.dnat = "10.0.100.40";
      }
    ];
    firewall.extraPostRoutes = [
      {
        oifname = "wg-ba";
        masquerade = true;
      }
      {
        iifname = "wg-ba";
        ip.daddr = "10.0.100.40";
        masquerade = true;
      }
    ];
    topology = {
      wan = {
        device = "00:e0:67:1b:70:34";
        network = { type = "disabled"; required = false; };
        vlans = {
          "vISP.wan" = {
            tag = 201;
            network = { type = "disabled"; required = false; };
            pppoe = {
              "pppwan" = {
                userfile = config.sops.secrets."pppd-userfile".path;
                network = { type = "dhcp"; nat.enable = true; route = "default"; trust = "external"; };
              };
            };
          };
        };
      };
      lan = {
        device = "00:e0:67:1b:70:35";
        network = { type = "disabled"; required = false; };
        vlans = {
          "vMGMT.lan" = {
            tag = 10;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.0.10.1/24"]; trust = "management"; };
          };
          "vHOME.lan" = {
            tag = 20;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.0.20.1/24"]; trust = "trusted"; };
          };
          "vADU.lan" = {
            tag = 31;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.0.31.1/24"]; dns = "cloudflare"; trust = "untrusted"; };
          };
          "vDMZ.lan" = {
            tag = 100;
            network = {
              type = "static";
              static-addresses = ["10.0.100.1/24"];
              dhcp.enable = true;
              trust = "untrusted";
            };
          };
        };
        batmanDevice = "bat0";
        mtu = "1536";
      };
      opt1 = {
        device = "00:e0:67:1b:70:36";
        network = { type = "disabled"; required = false; };
      };
      bat0 = {
        batman = {
          gatewayMode = "off";
          routingAlgorithm = "batman-v";
        };
        network = { type = "disabled"; required = false; };
        vlans = {
          "vMGMT.bat0" = {
            tag = 10;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.10.1/24"]; trust = "management"; };
          };
          "vHOME.bat0" = {
            tag = 20;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.20.1/24"]; trust = "trusted"; };
          };
          "vGUEST.bat0" = {
            tag = 30;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.30.1/24"]; trust = "untrusted"; };
          };
          "vIOT.bat0" = {
            tag = 40;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.40.1/24"]; trust = "untrusted"; };
          };
          "vGAME.bat0" = {
            tag = 41;
            network = { type = "static"; dhcp.enable = true; static-addresses = ["10.1.41.1/24"]; trust = "untrusted"; };
          };
        };
      };
      opt2 = {
        device = "00:e0:67:1b:70:37";
        network = { type = "disabled"; required = false; };
      };
      "wg-ba" = {
        network = {
          type = "static";
          static-addresses = [ "10.100.0.1/24" ];
          trust = "lockdown";
          required = false;
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-ba-privatekey".path;
          port = 38506;
          peers = [{
            allowedIps = [ "10.100.0.3/32" ];
            publicKey = "O+WWPlhy6Lg9YT3hYqq+/8gZ48PpRXaUTl4eFFwgTVA=";
            persistentKeepalive = 25;
          }];
          openFirewall = true;
        };
      };
      "wg-vpn" = {
        network = {
          type = "static";
          static-addresses = [ "10.100.10.1/24" ];
          trust = "trusted";
          required = false;
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-vpn-privatekey".path;
          port = 59362;
          peers = [{
            allowedIps = [ "10.100.10.20/32" ];
            publicKey = "sqPuQAWAKJzTice+L2kedo9X7Hx5WsMT/A6QXJVL/nA=";
          } {
            allowedIps = [ "10.100.10.21/32" ];
            publicKey = "8g4r9czA23tS/XTOajuIa/BNfDE2x4GwdXXi+udE6gY=";
          }];
          openFirewall = true;
        };
      };
      "wg-mx" = {
        network = {
          type = "static";
          static-addresses = [ "10.100.20.1/24" ];
          trust = "external";
          required = false;
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-mx-privatekey".path;
          port = 53973;
          peers = [{
            allowedIps = [ "10.100.20.10/32" ];
            publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
            endpoint = "helveticastandard.com:58156";
            dynamicEndpointRefreshRestartSeconds = 135;
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

  system.stateVersion = "21.11";

}
