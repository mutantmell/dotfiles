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
  inherit (net.hosts) ordis;
  inherit (net.hosts) roer;
  inherit (net.hosts) legram;
  inherit (net.hosts) ymir;

  # Helper to define a per-VLAN bridge with bond0 + bat0 members.
  # Batman-adv only carries mesh-encapsulated frames on hard interfaces,
  # so each VLAN needs its own bridge joining wired + mesh paths.
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
        dhcp6.enable = enableDhcp6;
      };
    };
  };

  vlanDefs = [
    # Network gear - APs and switches (locked down: NTP only)
    (mkVlanBridge {
      name = "MGMT";
      tag = 10;
      zone = "network";
      addresses = ["10.0.10.1/24" "10.97.10.1/24"];
      enableDhcp = false;
    })
    # Infrastructure - NAS, VM hosts, DNS
    (mkVlanBridge {
      name = "INFRA";
      tag = 11;
      zone = "management";
      addresses = ["10.0.11.1/24" "10.97.11.1/24"];
    })
    # Home network - trusted devices
    (mkVlanBridge {
      name = "HOME";
      tag = 20;
      zone = "trusted";
      addresses = ["10.0.20.1/24" "10.97.20.1/24"];
    })
    # Guest network - untrusted devices
    (mkVlanBridge {
      name = "GUEST";
      tag = 30;
      zone = "untrusted";
      addresses = ["10.0.30.1/24" "10.97.30.1/24"];
    })
    # ADU network - separate dwelling unit
    (mkVlanBridge {
      name = "ADU";
      tag = 31;
      zone = "untrusted";
      addresses = ["10.0.31.1/24" "10.97.31.1/24"];
    })
    # IoT network - smart home devices
    (mkVlanBridge {
      name = "IOT";
      tag = 40;
      zone = "untrusted";
      addresses = ["10.0.40.1/24" "10.97.40.1/24"];
    })
    # Gaming network - consoles and gaming devices
    (mkVlanBridge {
      name = "GAME";
      tag = 41;
      zone = "untrusted";
      addresses = ["10.0.41.1/24" "10.97.41.1/24"];
    })
    # DMZ network - exposed services
    (mkVlanBridge {
      name = "DMZ";
      tag = 100;
      zone = "untrusted";
      addresses = ["10.0.100.1/24" "10.97.100.1/24"];
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
        accessTo = ["management" "trusted" "untrusted" "external"];
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
            verdict = "accept";
            comment = "DNS + DHCP";
          }
          {
            tcp.dport = 53;
            verdict = "accept";
            comment = "DNS over TCP";
          }
        ];
      };

      vpn = {
        # Authenticated remote clients: access to infra + DMZ services, but not home LAN
        icmpEcho = "enable";
        accessTo = ["management" "untrusted"];
        inputRules = [
          {
            verdict = "accept";
            comment = "Full router service access";
          }
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
      upstream = [phantasma.ipv4]; # phantasma microVM (primary - has local hostnames)
      useDHCPFallback = true; # fall back to ISP DNS when phantasma microVM is down
      localDomain = "internal";
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
      # Forward from DMZ to wg-ba
      extraForwardRules = [
        {
          iifname = "brDMZ";
          oifname = "wg-ba";
          verdict = "accept";
        }
        {
          iifname = "wg-ba";
          ip.daddr = ordis.ipv4;
          verdict = "accept";
        }
        {
          iifname = "wg-ba";
          ip6.daddr = ordis.ipv6;
          verdict = "accept";
        }
        # ordis → roer (OIDC token exchange)
        {
          iifname = "brDMZ";
          oifname = "brINFRA";
          ip.saddr = ordis.ipv4;
          ip.daddr = roer.ipv4;
          tcp.dport = 443;
          verdict = "accept";
          comment = "ordis -> roer (OIDC)";
        }
        {
          iifname = "brDMZ";
          oifname = "brINFRA";
          ip6.saddr = ordis.ipv6;
          ip6.daddr = roer.ipv6;
          tcp.dport = 443;
          verdict = "accept";
          comment = "ordis -> roer (OIDC v6)";
        }
        # vDMZ → legram (ACME certificate issuance)
        {
          iifname = "brDMZ";
          oifname = "brINFRA";
          ip.daddr = legram.ipv4;
          tcp.dport = 443;
          verdict = "accept";
          comment = "vDMZ -> legram (ACME)";
        }
        {
          iifname = "brDMZ";
          oifname = "brINFRA";
          ip6.daddr = legram.ipv6;
          tcp.dport = 443;
          verdict = "accept";
          comment = "vDMZ -> legram (ACME v6)";
        }
        # vDMZ → ymir (Loki log push)
        {
          iifname = "brDMZ";
          oifname = "brINFRA";
          ip.daddr = ymir.ipv4;
          tcp.dport = 3100;
          verdict = "accept";
          comment = "vDMZ -> ymir (Loki)";
        }
        {
          iifname = "brDMZ";
          oifname = "brINFRA";
          ip6.daddr = ymir.ipv6;
          tcp.dport = 3100;
          verdict = "accept";
          comment = "vDMZ -> ymir (Loki v6)";
        }
      ];

      # Port forward SSH from wg-ba to ordis
      portForwards = [
        {
          proto = "tcp";
          sourcePort = 22;
          destination = "${ordis.ipv4}:22";
          sourceInterface = "wg-ba";
        }
      ];

      extraNatPostroutingRules = [
        # Wireguard BA tunnel masquerading
        {
          oifname = "wg-ba";
          masquerade = true;
        }
        {
          iifname = "wg-ba";
          ip.daddr = ordis.ipv4;
          masquerade = true;
        }
      ];

      extraNatRules = [
        # DNS interception - redirect bypass attempts to router's DNS
        # This catches devices (e.g., Google/Nest) that ignore DHCP-provided DNS
        # Excludes phantasma so Unbound can make recursive queries
        # Includes both 10.97 and legacy 10.0 addresses during migration
        {
          ip.saddr = {not = [phantasma.ipv4 phantasma.ipv4Legacy];};
          ip.daddr = {not = [host.ipv4 host.ipv4Legacy phantasma.ipv4 phantasma.ipv4Legacy];};
          udp.dport = 53;
          verdict = {dnat = "${host.ipv4Legacy}:53";};
          comment = "Intercept DNS bypass (UDP)";
        }
        {
          ip.saddr = {not = [phantasma.ipv4 phantasma.ipv4Legacy];};
          ip.daddr = {not = [host.ipv4 host.ipv4Legacy phantasma.ipv4 phantasma.ipv4Legacy];};
          tcp.dport = 53;
          verdict = {dnat = "${host.ipv4Legacy}:53";};
          comment = "Intercept DNS bypass (TCP)";
        }
      ];

      # IPv6 DNS interception - same as IPv4 but for ULA addresses
      # Excludes phantasma's IPv6 so Unbound can make recursive queries
      extraNat6Rules = [
        {
          ip6.saddr = {not = phantasma.ipv6;};
          ip6.daddr = {not = [host.ipv6 phantasma.ipv6];};
          udp.dport = 53;
          verdict = {dnat = "[${host.ipv6}]:53";};
          comment = "Intercept IPv6 DNS bypass (UDP)";
        }
        {
          ip6.saddr = {not = phantasma.ipv6;};
          ip6.daddr = {not = [host.ipv6 phantasma.ipv6];};
          tcp.dport = 53;
          verdict = {dnat = "[${host.ipv6}]:53";};
          comment = "Intercept IPv6 DNS bypass (TCP)";
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

        # Direct trusted port — bypasses bond/batman/bridge stack for quick DHCP testing
        opt2 = {
          mac = "00:e0:67:1b:70:37";
          network = {
            type = "static";
            addresses = ["10.0.21.1/24"];
            subnetId = 21;
            zone = "trusted";
            dhcp.enable = true;
            dhcp6.enable = true;
          };
        };

        # Wireguard - BA tunnel (isolated/lockdown)
        "wg-ba" = {
          kind = "wireguard";
          network = {
            type = "static";
            addresses = [
              "10.100.0.1/24"
              "fdc6:55f2:0a5e:6400::1/64" # Manual IPv6 for WG
            ];
            zone = "isolated";
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
            zone = "vpn";
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
      allow ${net.networks.network.subnet4Legacy}
      allow ${net.networks.network.subnet6}
      allow ${net.networks.management.subnet4}
      allow ${net.networks.management.subnet4Legacy}
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
