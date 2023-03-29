{ config, pkgs, sops-nix, ... }:

{
  imports =
    [
      ./hardware-configuration.nix

      sops-nix.nixosModules.sops
      ./sops.nix

      ../../modules/router.nix
    ];

  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
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

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      KbdInteractiveAuthentication = false;
    };
  };
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
  ];

  router = {
    enable = true;
    dns.upstream = "10.0.10.2";
    firewall.extraForwards = [
      {
        ip.saddr = "10.0.20.30";
        ip.daddr = "10.100.0.3";
        verdict = "accept";
      }
    ];
    topology = {
      wan = {
        device = "00:e0:67:1b:70:34";
        network = { type = "disabled"; };
        vlans = {
          "wanCENTURYLINK" = {
            tag = 201;
            network = { type = "disabled"; };
            pppoe = {
              "pppcenturylink" = {
                userfile = config.sops.secrets."pppd-userfile".path;
                network = { type = "dhcp"; nat.enable = true; route = "primary"; trust = "external"; };
              };
            };
          };
        };
      };
      lan = {
        device = "00:e0:67:1b:70:35";
        network = { type = "disabled"; };
        vlans = {
          "vMGMT.lan" = {
            tag = 10;
            network = { type = "routed"; ipv4 = "10.0.10.1/24"; trust = "management"; };
          };
          "vHOME.lan" = {
            tag = 20;
            network = { type = "routed"; ipv4 = "10.0.20.1/24"; trust = "trusted"; };
          };
          "vADU.lan" = {
            tag = 31;
            network = { type = "routed"; ipv4 = "10.0.31.1/24"; dns = "cloudflare"; trust = "untrusted"; };
          };
          "vDMZ.lan" = {
            tag = 100;
            network = {
              type = "static";
              static-addresses = ["10.0.100.1/24"];
              dhcp = {
                enable = true;
              };
              trust = "untrusted";
            };
            routes = [
              { gateway = "10.0.100.40"; destination = "10.100.1.0/24"; }
              { gateway = "10.0.100.40"; destination = "10.100.0.0/24"; }
            ];
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
        network = { type = "disabled"; };
        vlans = {
          "vMGMT.bat0" = {
            tag = 10;
            network = { type = "routed"; ipv4 = "10.1.10.1/24"; trust = "management"; };
          };
          "vHOME.bat0" = {
            tag = 20;
            network = { type = "routed"; ipv4 = "10.1.20.1/24"; trust = "trusted"; };
          };
          "vGUEST.bat0" = {
            tag = 30;
            network = { type = "routed"; ipv4 = "10.1.30.1/24"; trust = "untrusted"; };
          };
          "vIOT.bat0" = {
            tag = 40;
            network = { type = "routed"; ipv4 = "10.1.40.1/24"; trust = "untrusted"; };
          };
          "vGAME.bat0" = {
            tag = 41;
            network = { type = "routed"; ipv4 = "10.1.41.1/24"; trust = "untrusted"; };
          };
        };
      };
      opt2 = {
        device = "00:e0:67:1b:70:37";
        network = { type = "disabled"; required = false; };
      };
      "wg-vpn" = {
        network = {
          type = "static";
          static-addresses = [ "10.100.10.1/24" ];
          trust = "trusted";
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
        };
        wireguard = {
          privateKeyFile = config.sops.secrets."wg-mx-privatekey".path;
          port = 53973;
          peers = [{
            allowedIps = [ "10.100.20.10/32" ];
            publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
            endpoint = "helveticastandard.com:58156";
            persistentKeepalive = 25;
          }];
        };
      };
    };
  };

  system.stateVersion = "21.11";

}
