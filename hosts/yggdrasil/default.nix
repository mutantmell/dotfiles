{ config, pkgs, ... }:

let
  hostname = "yggdrasil";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host;
  alfheim = net.hosts.alfheim;
  surtr = net.hosts.surtr;
  bragi = net.hosts.bragi;
  njord = net.hosts.njord;
  gridr = net.hosts.gridr;
  mimir = net.hosts.mimir;
  tyr = net.hosts.tyr;
in {
  imports =
    [
      ./hardware-configuration.nix
      (import ../../profiles/disko/router.nix { })
      ./impermanence.nix
      ./sops.nix
      ./microvm.nix
    ];

  # Boot loader configuration is handled by disko
  boot.loader.grub.enable = true;

  # LUKS automatic unlock configuration
  # Note: UUID will be determined after deployment - update this after first boot
  # The keyFile here (/boot/secrets/disk.key) is for normal boots
  # During installation, disko uses /tmp/secret.key temporarily (see disko profile)
  # boot.initrd.luks.devices."cryptroot" = {
  #   device = "/dev/disk/by-uuid/PLACEHOLDER-UPDATE-AFTER-DEPLOYMENT";
  #   keyFile = "/boot/secrets/disk.key";
  #   allowDiscards = true;
  # };

  # Ensure /boot/secrets directory exists
  system.activationScripts.createBootSecrets = ''
    mkdir -p /boot/secrets
    chmod 700 /boot/secrets
  '';

  networking.hostName = hostname;
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

    zones = {
      external = {
        # WAN: no access to anything, no router services
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };

      network = {
        # Network gear (APs, switches): NTP only, no internet, no lateral movement
        icmpEcho = "enable";
        accessTo = [];
        inputRules = [
          { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
        ];
      };

      management = {
        # Infrastructure: full router access, filtered internet egress
        icmpEcho = "enable";
        accessTo = [ "management" "trusted" "untrusted" ];
        forwardRules.external = [
          { udp.dport = 53; verdict = "accept"; comment = "DNS recursive queries"; }
          { tcp.dport = 53; verdict = "accept"; comment = "DNS recursive queries (TCP)"; }
          { tcp.dport = 80; verdict = "accept"; comment = "HTTP for package mirrors"; }
          { tcp.dport = 443; verdict = "accept"; comment = "HTTPS for updates"; }
          { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
        ];
        inputRules = [
          { verdict = "accept"; comment = "Full router service access"; }
        ];
      };

      trusted = {
        # User devices: full router access, can reach all internal + internet
        icmpEcho = "enable";
        accessTo = [ "management" "trusted" "untrusted" "external" ];
        inputRules = [
          { verdict = "accept"; comment = "Full router service access"; }
        ];
      };

      untrusted = {
        # Guest/IoT: DNS + DHCP only, internet only, no lateral movement
        icmpEcho = "enable";
        accessTo = [ "external" ];
        inputRules = [
          { udp.dport = [ 53 67 547 ]; verdict = "accept"; comment = "DNS + DHCP"; }
          { tcp.dport = 53; verdict = "accept"; comment = "DNS over TCP"; }
        ];
      };

      isolated = {
        # No forwarding, no router services
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
    };

    dns = {
      upstream = [ alfheim.ipv4 ];  # alfheim microVM (primary - has local hostnames)
      useDHCPFallback = true;       # fall back to ISP DNS when alfheim microVM is down
      localDomain = "local";
    };

    firewall = {
      # Forward from DMZ to wg-ba
      extraForwardRules = [
        { iifname = "vDMZ.br0"; oifname = "wg-ba"; verdict = "accept"; }
        { iifname = "wg-ba"; ip.daddr = surtr.ipv4; verdict = "accept"; }
        # surtr → mimir (OIDC token exchange)
        { iifname = "vDMZ.br0"; oifname = "vINFRA.br0";
          ip.saddr = surtr.ipv4; ip.daddr = mimir.ipv4;
          tcp.dport = 443; verdict = "accept"; comment = "surtr -> mimir (OIDC)"; }
        # vDMZ → tyr (ACME certificate issuance)
        { iifname = "vDMZ.br0"; oifname = "vINFRA.br0";
          ip.daddr = tyr.ipv4; tcp.dport = 443;
          verdict = "accept"; comment = "vDMZ -> tyr (ACME)"; }
      ];

      # Port forward SSH from wg-ba to surtr
      portForwards = [
        {
          proto = "tcp";
          sourcePort = 22;
          destination = "${surtr.ipv4}:22";
          sourceInterface = "wg-ba";
        }
      ];

      extraNatRules = [
        # Wireguard BA tunnel masquerading
        { oifname = "wg-ba"; masquerade = true; }
        { iifname = "wg-ba"; ip.daddr = surtr.ipv4; masquerade = true; }

        # DNS interception - redirect bypass attempts to router's DNS
        # This catches devices (e.g., Google/Nest) that ignore DHCP-provided DNS
        # Excludes alfheim so Unbound can make recursive queries
        {
          ip.saddr = { not = alfheim.ipv4; };
          ip.daddr = { not = [ host.ipv4 alfheim.ipv4 ]; };
          udp.dport = 53;
          verdict = { dnat = "${host.ipv4}:53"; };
          comment = "Intercept DNS bypass (UDP)";
        }
        {
          ip.saddr = { not = alfheim.ipv4; };
          ip.daddr = { not = [ host.ipv4 alfheim.ipv4 ]; };
          tcp.dport = 53;
          verdict = { dnat = "${host.ipv4}:53"; };
          comment = "Intercept DNS bypass (TCP)";
        }
      ];

      # IPv6 DNS interception - same as IPv4 but for ULA addresses
      # Excludes alfheim's IPv6 so Unbound can make recursive queries
      extraNat6Rules = [
        {
          ip6.saddr = { not = alfheim.ipv6; };
          ip6.daddr = { not = [ host.ipv6 alfheim.ipv6 ]; };
          udp.dport = 53;
          verdict = { dnat = "[${host.ipv6}]:53"; };
          comment = "Intercept IPv6 DNS bypass (UDP)";
        }
        {
          ip6.saddr = { not = alfheim.ipv6; };
          ip6.daddr = { not = [ host.ipv6 alfheim.ipv6 ]; };
          tcp.dport = 53;
          verdict = { dnat = "[${host.ipv6}]:53"; };
          comment = "Intercept IPv6 DNS bypass (TCP)";
        }
      ];
    };

    topology = {
      # WAN interface - DHCP from ISP
      wan = {
        mac = "00:e0:67:1b:70:34";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
          defaultRoute = true;
        };
      };

      # LAN interface - will be bonded
      lan = {
        mac = "00:e0:67:1b:70:35";
      };

      # Second LAN interface - will be bonded
      opt1 = {
        mac = "00:e0:67:1b:70:36";
      };

      # Bond combining lan + opt1 for increased bandwidth (LACP)
      bond0 = {
        kind = "bond";
        mode = "802.3ad";
        lacpTransmitRate = "fast";
        miiMonitorSec = "100ms";
        members = ["lan" "opt1"];
        network = {
          type = "disabled";
          mtu = 1536;
        };
      };

      # Batman-adv mesh device
      bat0 = {
        kind = "batman";
        members = ["bond0"];  # Batman lists its members
        batman = {
          gatewayMode = "off";
          routingAlgorithm = "batman-v";
        };
        network.type = "disabled";
      };

      # Bridge combining bond0 and bat0 - all VLANs created on top
      # bond0 is both a batman member (via bat0.members) and a bridge member
      # bat0 is also a bridge member
      br0 = {
        kind = "bridge";
        members = ["bond0" "bat0"];
        network.type = "disabled";
        vlans = {
          # Network gear - APs and switches (locked down: NTP only)
          "vMGMT.br0" = {
            tag = 10;  # -> fdc6:55f2:0a5e:a::1/64
            network = {
              type = "static";
              addresses = [ "10.0.10.1/24" ];
              subnetId = 10;
              zone = "network";
              dhcp6.enable = true;
            };
          };

          # Infrastructure - NAS, VM hosts, DNS
          "vINFRA.br0" = {
            tag = 11;  # -> fdc6:55f2:0a5e:b::1/64
            network = {
              type = "static";
              addresses = [ "10.0.11.1/24" ];
              subnetId = 11;
              zone = "management";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };

          # Home network - trusted devices
          "vHOME.br0" = {
            tag = 20;  # -> fdc6:55f2:0a5e:14::1/64
            network = {
              type = "static";
              addresses = [ "10.0.20.1/24" ];
              subnetId = 20;
              zone = "trusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };

          # Guest network - untrusted devices
          "vGUEST.br0" = {
            tag = 30;  # -> fdc6:55f2:0a5e:1e::1/64
            network = {
              type = "static";
              addresses = [ "10.0.30.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };

          # ADU network - separate dwelling unit
          "vADU.br0" = {
            tag = 31;  # -> fdc6:55f2:0a5e:1f::1/64
            network = {
              type = "static";
              addresses = [ "10.0.31.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };

          # IoT network - smart home devices
          "vIOT.br0" = {
            tag = 40;  # -> fdc6:55f2:0a5e:28::1/64
            network = {
              type = "static";
              addresses = [ "10.0.40.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };

          # Gaming network - consoles and gaming devices
          "vGAME.br0" = {
            tag = 41;  # -> fdc6:55f2:0a5e:29::1/64
            network = {
              type = "static";
              addresses = [ "10.0.41.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };

          # DMZ network - exposed services
          "vDMZ.br0" = {
            tag = 100;  # -> fdc6:55f2:0a5e:64::1/64
            network = {
              type = "static";
              addresses = [ "10.0.100.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };
        };
      };

      # Spare interface
      opt2 = {
        mac = "00:e0:67:1b:70:37";
      };

      # Wireguard - BA tunnel (isolated/lockdown)
      "wg-ba" = {
        kind = "wireguard";
        network = {
          type = "static";
          addresses = [
            "10.100.0.1/24"
            "fdc6:55f2:0a5e:6400::1/64"  # Manual IPv6 for WG
          ];
          zone = "isolated";
          required = false;  # External connection, don't block boot
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
        kind = "wireguard";
        network = {
          type = "static";
          addresses = [
            "10.100.10.1/24"
            "fdc6:55f2:0a5e:640a::1/64"  # Manual IPv6 for WG
          ];
          zone = "trusted";
          required = false;  # External connection, don't block boot
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

    };
  };

  # Bridge microVM tap interfaces into the infrastructure network
  # The vm-11-alfheim tap interface is created by microvm and needs to be bridged to vINFRA.br0
  systemd.network.networks."10-vm-infra" = {
    matchConfig.Name = "vm-11-*";
    networkConfig = {
      Bridge = "vINFRA.br0";
      DHCP = "no";
      LinkLocalAddressing = "no";
    };
    linkConfig.RequiredForOnline = "no";
  };

  networking.extraHosts = ''
    ${host.ipv4} yggdrasil
    ${host.ipv4} yggdrasil.local
    ${host.ipv6} yggdrasil.local
    ${alfheim.ipv4} alfheim
    ${alfheim.ipv4} alfheim.local
    ${alfheim.ipv6} alfheim.local
    ${gridr.ipv4} gridr.local
    ${mimir.ipv4} mimir.local
    ${tyr.ipv4} tyr.local
    ${surtr.ipv4} surtr.local
    ${bragi.ipv4} bragi.local
    ${njord.ipv4} njord.local
  '';

  # NTP server for network gear and infrastructure
  services.chrony = {
    enable = true;
    extraConfig = ''
      allow ${net.networks.network.subnet4}
      allow ${net.networks.management.subnet4}
    '';
  };

  # Persistence for router state
  environment.persistence."/persist".directories = [
    "/var/lib/kea"
    "/var/lib/knot-resolver"
  ];

  home-manager.users.root = {
    home.stateVersion = "23.11";
    programs.git = {
      enable = true;
      settings = {
        user.name = "mutantmell";
        user.email = "malaguy@gmail.com";
        core.sshCommand = "ssh -i /etc/ssh/ssh_host_ed25519_key";
      };
    };
  };

  system.stateVersion = "24.05";

}
