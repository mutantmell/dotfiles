# Router6 network configuration for thebeyond
#
# Per-VLAN bridge topology: bond0 (wired trunk) + bat0 (batman mesh) → per-VLAN bridges
# Each VLAN gets a bridge joining bond0 and bat0 VLAN sub-interfaces, with IP/DHCP/zone config.
# This is the standard batman-adv deployment pattern for multi-VLAN networks.
#
# Topology:
#   Physical NICs → bond0 (LACP) → bat0 (batman-adv mesh)
#   bond0 VLANs (wired) + bat0 VLANs (mesh) → per-VLAN bridges (brMGMT, brINFRA, brHOME, ...)
#   Each bridge gets: static IPs, DHCP server, firewall zone assignment
{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost "thebeyond") host;
  inherit (net.hosts) phantasma;
  inherit (net.hosts) langport;
  inherit (net.hosts) trista;
  inherit (net.hosts) messeldam;
  inherit (net.hosts) basel;
  inherit (net.hosts) tharbad;

  # Helper to define a per-VLAN bridge with bond0 + bat0 members.
  # Batman-adv only carries mesh-encapsulated frames on hard interfaces,
  # so each VLAN needs its own bridge joining wired + mesh paths.
  # ULA base for computing per-VLAN DNS addresses
  ulaBase = "fdc6:55f2:a5e";

  mkVlanBridge = {
    name,
    tag,
    addresses,
    zone,
    enableDhcp ? true,
    enableDhcp6 ? true,
  }: {
    bond0Vlans."v${name}.bond0" = {
      inherit tag;
      network.type = "disabled";
    };
    bat0Vlans."v${name}.bat0" = {
      inherit tag;
      network.type = "disabled";
    };
    bridges."br${name}" = {
      kind = "bridge";
      members = ["v${name}.bond0" "v${name}.bat0"];
      network = {
        type = "static";
        inherit addresses zone;
        subnetId = tag;
        dhcp.enable = enableDhcp;
        dhcp6 = {
          enable = enableDhcp6;
          dnsAddress =
            if enableDhcp6
            then "${ulaBase}:${lib.toLower (lib.toHexString tag)}::1"
            else null;
        };
      };
    };
  };

  vlanDefs = [
    # Network gear - APs and switches (locked down: NTP only)
    (mkVlanBridge {
      name = "MGMT";
      tag = 10;
      zone = "network";
      addresses = ["10.97.10.1/24"];
      enableDhcp = false;
    })
    # Infrastructure - NAS, VM hosts, DNS
    (mkVlanBridge {
      name = "INFRA";
      tag = 11;
      zone = "management";
      addresses = ["10.97.11.1/24"];
    })
    # Home network - trusted devices
    (mkVlanBridge {
      name = "HOME";
      tag = 20;
      zone = "trusted";
      addresses = ["10.97.20.1/24"];
    })
    # Guest network - untrusted devices
    (mkVlanBridge {
      name = "GUEST";
      tag = 30;
      zone = "untrusted";
      addresses = ["10.97.30.1/24"];
    })
    # ADU network - separate dwelling unit
    (mkVlanBridge {
      name = "ADU";
      tag = 31;
      zone = "untrusted";
      addresses = ["10.97.31.1/24"];
    })
    # IoT network - smart home devices
    (mkVlanBridge {
      name = "IOT";
      tag = 40;
      zone = "untrusted";
      addresses = ["10.97.40.1/24"];
    })
    # Gaming network - consoles and gaming devices
    (mkVlanBridge {
      name = "GAME";
      tag = 41;
      zone = "untrusted";
      addresses = ["10.97.41.1/24"];
    })
    # Lab network - semi-trusted dev environments (edith, trista, wg-vpn)
    (mkVlanBridge {
      name = "LAB";
      tag = 21;
      zone = "lab";
      addresses = ["10.97.21.1/24"];
    })
    # DMZ network - exposed services
    (mkVlanBridge {
      name = "DMZ";
      tag = 100;
      zone = "dmz";
      addresses = ["10.97.100.1/24"];
    })
  ];

  allBond0Vlans = lib.foldl' (a: b: a // b.bond0Vlans) {} vlanDefs;
  allBat0Vlans = lib.foldl' (a: b: a // b.bat0Vlans) {} vlanDefs;
  allBridges = lib.foldl' (a: b: a // b.bridges) {} vlanDefs;
in {
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
          {
            udp.dport = 123;
            verdict = "accept";
            comment = "NTP";
          }
        ];
      };

      management = {
        # Infrastructure: full router access, filtered internet egress
        icmpEcho = "enable";
        accessTo = ["management" "trusted" "untrusted"];
        # tharbad → DMZ/lab for Prometheus scraping
        forwardRules.dmz = [
          {
            ip.saddr = tharbad.ipv4;
            tcp.dport = 9100;
            verdict = "accept";
            comment = "tharbad -> DMZ (node_exporter)";
          }
          {
            ip6.saddr = tharbad.ipv6;
            tcp.dport = 9100;
            verdict = "accept";
            comment = "tharbad -> DMZ (node_exporter v6)";
          }
        ];
        forwardRules.lab = [
          {
            ip.saddr = tharbad.ipv4;
            tcp.dport = 9100;
            verdict = "accept";
            comment = "tharbad -> lab (node_exporter)";
          }
          {
            ip6.saddr = tharbad.ipv6;
            tcp.dport = 9100;
            verdict = "accept";
            comment = "tharbad -> lab (node_exporter v6)";
          }
        ];
        forwardRules.external = [
          {
            udp.dport = 53;
            verdict = "accept";
            comment = "DNS recursive queries";
          }
          {
            tcp.dport = 53;
            verdict = "accept";
            comment = "DNS recursive queries (TCP)";
          }
          {
            tcp.dport = 80;
            verdict = "accept";
            comment = "HTTP for package mirrors";
          }
          {
            tcp.dport = 443;
            verdict = "accept";
            comment = "HTTPS for updates";
          }
          {
            udp.dport = 123;
            verdict = "accept";
            comment = "NTP";
          }
        ];
        inputRules = [
          {
            verdict = "accept";
            comment = "Full router service access";
          }
        ];
      };

      trusted = {
        # User devices: full router access, can reach all internal + internet
        icmpEcho = "enable";
        accessTo = ["management" "trusted" "lab" "untrusted" "external"];
        inputRules = [
          {
            verdict = "accept";
            comment = "Full router service access";
          }
        ];
      };

      untrusted = {
        # Guest/IoT: DNS + DHCP only, internet only, no lateral movement
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [
          {
            udp.dport = [53 67 547];
            limit = "100/second";
            verdict = "accept";
            comment = "DNS + DHCP";
          }
          {
            tcp.dport = 53;
            limit = "100/second";
            verdict = "accept";
            comment = "DNS over TCP";
          }
        ];
      };

      dmz = {
        # DMZ: restricted internet + selective cross-zone access (management services, ba-tunnel)
        icmpEcho = "enable";
        accessTo = [];
        forwardRules.external = [
          {
            tcp.dport = 22;
            verdict = "accept";
            comment = "DMZ -> internet (SSH)";
          }
          {
            tcp.dport = 80;
            verdict = "accept";
            comment = "DMZ -> internet (HTTP)";
          }
          {
            tcp.dport = 443;
            verdict = "accept";
            comment = "DMZ -> internet (HTTPS)";
          }
        ];
        inputRules = [
          {
            udp.dport = [53 67 547];
            limit = "100/second";
            verdict = "accept";
            comment = "DNS + DHCP";
          }
          {
            tcp.dport = 53;
            limit = "100/second";
            verdict = "accept";
            comment = "DNS over TCP";
          }
        ];
        forwardRules.management = [
          # langport → messeldam (OIDC token exchange)
          {
            ip.saddr = langport.ipv4;
            ip.daddr = messeldam.ipv4;
            tcp.dport = 443;
            verdict = "accept";
            comment = "langport -> messeldam (OIDC)";
          }
          {
            ip6.saddr = langport.ipv6;
            ip6.daddr = messeldam.ipv6;
            tcp.dport = 443;
            verdict = "accept";
            comment = "langport -> messeldam (OIDC v6)";
          }
          # DMZ → basel (ACME certificate issuance)
          {
            ip.daddr = basel.ipv4;
            tcp.dport = 443;
            verdict = "accept";
            comment = "DMZ -> basel (ACME)";
          }
          {
            ip6.daddr = basel.ipv6;
            tcp.dport = 443;
            verdict = "accept";
            comment = "DMZ -> basel (ACME v6)";
          }
          # DMZ → tharbad (Loki log push)
          {
            ip.daddr = tharbad.ipv4;
            tcp.dport = 3100;
            verdict = "accept";
            comment = "DMZ -> tharbad (Loki)";
          }
          {
            ip6.daddr = tharbad.ipv6;
            tcp.dport = 3100;
            verdict = "accept";
            comment = "DMZ -> tharbad (Loki v6)";
          }
        ];
      };

      ba-tunnel = {
        # wg-ba: mesh peer tunnel, locked down to trista SSH bastion only
        icmpEcho = "disable";
        accessTo = [];
        forwardRules.dmz = [
          {
            ip.daddr = trista.ipv4;
            tcp.dport = 22;
            verdict = "accept";
            comment = "wg-ba -> trista SSH (v4)";
          }
          {
            ip6.daddr = trista.ipv6;
            tcp.dport = 22;
            verdict = "accept";
            comment = "wg-ba -> trista SSH (v6)";
          }
        ];
        inputRules = [];
      };

      lab = {
        # Semi-trusted: dev environments + VPN clients. Can reach infra services
        # and DMZ but NOT trusted (asymmetric containment for personal devices).
        # Self-referential access needed for wg-vpn (10.100.10.0/24) → lab hosts
        # (10.97.21.0/24) since they cross interfaces and hit the forward chain.
        icmpEcho = "enable";
        accessTo = ["management" "lab" "dmz" "external"];
        inputRules = [
          {
            verdict = "accept";
            comment = "Full router service access";
          }
        ];
      };

      isolated = {
        # No forwarding, no router services (available for future use)
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
    };

    dns = {
      upstream = [phantasma.ipv4]; # phantasma microVM (primary - has local hostnames)
      useDHCPFallback = true; # fall back to ISP DNS when phantasma microVM is down
      localDomain = "internal";
      interception = {
        enable = true;
        extraExcludeAddresses = [phantasma.ipv6];
        target = host.ipv4;
        target6 = host.ipv6;
      };
    };

    dyndns = {
      enable = false; # Still need to set up w/ the new host once we have it.
      protocol = "namecheap";
      server = "https://dynamicdns.park-your-domain.com";
      hosts = ["@"];
      domainFile = config.sops.secrets."dyndns-host-domain".path;
      passwordFile = config.sops.secrets."dyndns-host-password".path;
    };

    firewall = {
      icmpRateLimit = "30/second burst 60 packets";
      logDropped = true;

      egressPolicy = "drop";
      egressRules = [
        # DNS (kresd recursive queries)
        {
          udp.dport = 53;
          verdict = "accept";
          comment = "DNS recursive";
        }
        {
          tcp.dport = 53;
          verdict = "accept";
          comment = "DNS recursive (TCP)";
        }
        # NTP
        {
          udp.dport = 123;
          verdict = "accept";
          comment = "NTP";
        }
        # DHCP client
        {
          udp.dport = 67;
          verdict = "accept";
          comment = "DHCP client";
        }
        {
          udp.dport = 68;
          verdict = "accept";
          comment = "DHCP server response";
        }
        # DHCPv6
        {
          udp.dport = [546 547];
          verdict = "accept";
          comment = "DHCPv6";
        }
        # HTTP/HTTPS (system updates)
        {
          tcp.dport = 80;
          verdict = "accept";
          comment = "HTTP";
        }
        {
          tcp.dport = 443;
          verdict = "accept";
          comment = "HTTPS";
        }
        # WireGuard
        {
          udp.dport = [38506 59362];
          verdict = "accept";
          comment = "WireGuard";
        }
      ];
      # Port forward SSH from wg-ba to trista (SSH bastion)
      portForwards = [
        {
          proto = "tcp";
          sourcePort = 22;
          destination = "${trista.ipv4}:22";
          sourceInterface = "wg-ba";
          destinationInterface = "brDMZ";
        }
      ];

      extraNatPostroutingRules = [
        # Wireguard BA tunnel masquerading
        {
          oifname = "wg-ba";
          masquerade = true;
        }
      ];
    };

    topology =
      {
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
          vlans = allBond0Vlans;
        };

        # Batman-adv mesh device
        bat0 = {
          kind = "batman";
          members = ["bond0"];
          batman = {
            gatewayMode = "off";
            routingAlgorithm = "batman-v";
          };
          network.type = "disabled";
          vlans = allBat0Vlans;
        };

        # Wireguard - BA tunnel (mesh peer, trista SSH only)
        "wg-ba" = {
          kind = "wireguard";
          network = {
            type = "static";
            addresses = [
              "10.100.0.1/24"
              "fdc6:55f2:0a5e:6400::1/64" # Manual IPv6 for WG
            ];
            zone = "ba-tunnel";
            required = false; # External connection, don't block boot
          };
          wireguard = {
            privateKeyFile = config.sops.secrets."wg-ba-privatekey".path;
            port = 38506;
            openFirewall = true;
            peers = [
              {
                publicKey = "O+WWPlhy6Lg9YT3hYqq+/8gZ48PpRXaUTl4eFFwgTVA=";
                allowedIPs = ["10.100.0.3/32" "fdc6:55f2:0a5e:6400::3/128"];
                persistentKeepalive = 25;
              }
            ];
          };
        };

        # Wireguard - VPN for mobile devices
        "wg-vpn" = {
          kind = "wireguard";
          network = {
            type = "static";
            addresses = [
              "10.100.10.1/24"
              "fdc6:55f2:0a5e:640a::1/64" # Manual IPv6 for WG
            ];
            zone = "lab";
            required = false; # External connection, don't block boot
          };
          wireguard = {
            privateKeyFile = config.sops.secrets."wg-vpn-privatekey".path;
            port = 59362;
            openFirewall = true;
            peers = [
              {
                publicKey = "sqPuQAWAKJzTice+L2kedo9X7Hx5WsMT/A6QXJVL/nA=";
                allowedIPs = ["10.100.10.20/32" "fdc6:55f2:0a5e:640a::14/128"];
              }
              {
                publicKey = "8g4r9czA23tS/XTOajuIa/BNfDE2x4GwdXXi+udE6gY=";
                allowedIPs = ["10.100.10.21/32" "fdc6:55f2:0a5e:640a::15/128"];
              }
            ];
          };
        };
      }
      // allBridges;
  };

  # Bridge microVM tap interfaces into the infrastructure network
  # The vm-11-phantasma tap interface is created by microvm and needs to be bridged to brINFRA
  systemd.network.networks."10-vm-infra" = {
    matchConfig.Name = "vm-11-*";
    networkConfig = {
      Bridge = "brINFRA";
      DHCP = "no";
      LinkLocalAddressing = "no";
    };
    linkConfig.RequiredForOnline = "no";
  };

  # NTP server for network gear and infrastructure
  services.chrony = {
    enable = true;
    extraConfig = ''
      allow ${net.networks.network.subnet4}
      allow ${net.networks.network.subnet6}
      allow ${net.networks.management.subnet4}
      allow ${net.networks.management.subnet6}
    '';
  };

  # Persistence for router state
  # kea uses DynamicUser=true, so its state lives under /var/lib/private/kea
  # (systemd manages the /var/lib/kea -> /var/lib/private/kea symlink)
  environment.persistence.${config.common.impermanence.persistDir}.directories = [
    "/var/lib/private/kea"
    "/var/lib/knot-resolver"
  ];
}
