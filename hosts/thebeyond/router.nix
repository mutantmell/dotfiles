# Router6 network configuration for thebeyond
#
# Per-VLAN bridge topology: enp2s0 (wired to BT8-bridge) → bat0 (batman-adv) → per-VLAN bridges.
# bond0 is gone: VP2440 uses a single wired port as the batman hard interface.
# Bridges are bat0-only (no bond0 VLAN sub-interfaces).
#
# Topology:
#   enp2s0 (wired to BT8-bridge, mtu=1536) → bat0 (batman-adv mesh) → bat0.<tag> VLANs
#   bat0 VLANs → per-VLAN bridges (brMGMT, brINFRA, brHOME, ...)
#   Each bridge gets: static IPs (derived from network registry), DHCP server, firewall zone
#
# Note: topology keys are kernel-assigned predictable names (enp2s0/enp4s0) rather
# than logical aliases. The `hardwareName`-driven rename machinery in router6/
# networking.nix emits `OriginalName=enpXsY` in the .link file, which doesn't
# match at boot (the kernel-assigned name is eth0 at device-add). See checklist
# "Outstanding open items" — fix the .link match strategy before reintroducing
# logical names.
{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  wg = net.wireguardNetworks;
  ds = net.mkDualStackRules;
  inherit (net.forHost "thebeyond") host;
  inherit (net.hosts) phantasma;
  inherit (net.hosts) bt8bridge;
  inherit (net.hosts) langport;
  inherit (net.hosts) trista;
  inherit (net.hosts) messeldam;
  inherit (net.hosts) basel;
  inherit (net.hosts) tharbad;
  inherit (net.hosts) oracion;

  # Maps registry subnet name → { bridgeName, zone, enableDhcp?, enableDhcp6? }.
  # The subnet name is the key into net.networks and determines IP addressing
  # (gateway4, prefixLength4, vlanId). The zone field is the router6 firewall
  # security policy — independent of subnet identity. Multiple subnets can share
  # a zone (e.g. adu/iot/game all use "untrusted") without any registry hack.
  subnetBindings = {
    network = {
      bridgeName = "MGMT";
      zone = "network";
      enableDhcp = false;
      enableDhcp6 = false;
    };
    untrusted = {
      bridgeName = "GUEST";
      zone = "untrusted";
    };
    adu = {
      bridgeName = "ADU";
      zone = "untrusted";
    };
    iot = {
      bridgeName = "IOT";
      zone = "untrusted";
    };
    game = {
      bridgeName = "GAME";
      zone = "untrusted";
    };
    dmz = {
      bridgeName = "DMZ";
      zone = "dmz";
    };
  };

  mkVlanBridge = subnetName: {
    bridgeName,
    zone,
    enableDhcp ? true,
    enableDhcp6 ? true,
  }: let
    subnet = net.networks.${subnetName};
  in {
    bat0Vlans."v${bridgeName}.bat0" = {
      tag = subnet.vlanId;
      network.type = "disabled";
    };
    bridges."br${bridgeName}" = {
      kind = "bridge";
      members = ["v${bridgeName}.bat0"];
      network = {
        type = "static";
        # Both v4 and v6 are explicit. Letting router6 auto-derive the v6
        # address from the VLAN tag alone breaks bt8gw-owned subnets that
        # currently live on thebeyond: router6 would assign
        # `<ulaPrefix>:<vlanHex>::1` while the registry's gateway6 (used
        # for RA DNS emission) is `<ulaPrefix>:<groupHex><vlanHex>::1`.
        # For group 1 (bt8gw) those are different addresses, so the RA
        # advertises a DNS server nothing on the segment actually claims —
        # clients then stall ~5s per first-query on the v6 path.
        addresses = [
          "${subnet.gateway4}/${toString subnet.prefixLength4}"
          "${subnet.gateway6}/${toString subnet.prefixLength6}"
        ];
        inherit zone;
        subnetId = subnet.vlanId;
        dhcp.enable = enableDhcp;
        dhcp6 = {
          enable = enableDhcp6;
          dnsAddress =
            if enableDhcp6
            then subnet.gateway6
            else null;
        };
      };
    };
  };

  # L2-only batman passthrough: bridge carries the VLAN across the mesh but
  # holds no IP, no zone, no DHCP on thebeyond. The actual L3 gateway lives
  # elsewhere (APP/50 terminates on BT8-gateway, not thebeyond).
  mkMemberOnlyBridge = subnetName: {bridgeName}: let
    subnet = net.networks.${subnetName};
  in {
    bat0Vlans."v${bridgeName}.bat0" = {
      tag = subnet.vlanId;
      network.type = "disabled";
    };
    bridges."br${bridgeName}" = {
      kind = "bridge";
      members = ["v${bridgeName}.bat0"];
      network.type = "disabled";
    };
  };

  # Transit: point-to-point /30 + /64 link between thebeyond and BT8-gateway.
  # Static on both sides (no DHCP) — BT8-gateway's `.2` address is fixed via
  # runbook B. IPv6 is set explicitly (not via DHCP6 auto-derivation) so the
  # bridge has both AFs without running RA/DHCPv6 on a point-to-point link.
  transitBridge = let
    subnet = net.networks.transit;
  in {
    bat0Vlans."vTRANSIT.bat0" = {
      tag = subnet.vlanId;
      network.type = "disabled";
    };
    bridges.brTRANSIT = {
      kind = "bridge";
      members = ["vTRANSIT.bat0"];
      network = {
        type = "static";
        addresses = [
          "${subnet.gateway4}/${toString subnet.prefixLength4}"
          "${subnet.gateway6}/${toString subnet.prefixLength6}"
        ];
        zone = "transit";
        subnetId = subnet.vlanId;
      };
    };
  };

  vlanDefs =
    (lib.mapAttrsToList mkVlanBridge subnetBindings)
    ++ [
      (mkMemberOnlyBridge "app" {bridgeName = "APP";})
      transitBridge
    ];

  allBat0Vlans = lib.foldl' (a: b: a // b.bat0Vlans) {} vlanDefs;
  allBridges = lib.foldl' (a: b: a // b.bridges) {} vlanDefs;
in {
  router6 = {
    enable = true;

    # ULA prefix for internal IPv6 addressing
    ulaPrefix = "fdc6:55f2:0a5e::/48";

    zones = {
      external = {
        # WAN: no access to anything, no router services
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };

      network = {
        # Network gear (APs, switches): NTP + DNS only, no internet, no lateral movement.
        # phantasma (recursive DNS resolver) lives here — kresd auto-binds to brMGMT
        # because inputRules allows DNS below.
        icmpEcho = "enable";
        accessTo = [];
        # phantasma is the recursive resolver for the whole network. It must be
        # able to reach root servers (DNS) and NTP servers (for DNSSEC clock
        # alignment). Restricted to phantasma's IPs so general network-zone gear
        # (APs/switches) does NOT inherit internet egress.
        forwardRules.external =
          (ds {
            saddr = phantasma;
            udp.dport = 53;
            verdict = "accept";
            comment = "phantasma -> internet (recursive DNS)";
          })
          ++ (ds {
            saddr = phantasma;
            tcp.dport = 53;
            verdict = "accept";
            comment = "phantasma -> internet (recursive DNS TCP)";
          })
          ++ (ds {
            saddr = phantasma;
            udp.dport = 123;
            verdict = "accept";
            comment = "phantasma -> internet (NTP, for DNSSEC clock)";
          });
        inputRules = [
          {
            udp.dport = 123;
            verdict = "accept";
            comment = "NTP";
          }
          # DNS: thebeyond's local kresd → phantasma (same L2 segment, input-chain flow)
          {
            udp.dport = 53;
            verdict = "accept";
            comment = "DNS";
          }
          {
            tcp.dport = 53;
            verdict = "accept";
            comment = "DNS (TCP)";
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
        # DMZ-initiated flows to management-zone services. Pre-Phase-3 these
        # were `forwardRules.management` (local on thebeyond, brDMZ → brINFRA);
        # post-Phase-3 the destination IPs (messeldam/basel/tharbad) live
        # on BT8-gateway, so the path is brDMZ → brTRANSIT and the rules live
        # under `forwardRules.transit`. The daddr constraints still gate by
        # specific host so transit traffic to other zones isn't broadened.
        forwardRules.transit =
          # langport → messeldam (OIDC token exchange)
          (ds {
            saddr = langport;
            daddr = messeldam;
            tcp.dport = 443;
            verdict = "accept";
            comment = "langport -> messeldam (OIDC) [via BT8-gateway]";
          })
          # DMZ → basel (ACME certificate issuance)
          ++ (ds {
            daddr = basel;
            tcp.dport = 443;
            verdict = "accept";
            comment = "DMZ -> basel (ACME) [via BT8-gateway]";
          })
          # DMZ → tharbad (Loki log push)
          ++ (ds {
            daddr = tharbad;
            tcp.dport = 3100;
            verdict = "accept";
            comment = "DMZ -> tharbad (Loki) [via BT8-gateway]";
          });
      };

      ba-tunnel = {
        # wg-ba: mesh peer tunnel, locked down to trista SSH bastion only
        icmpEcho = "disable";
        accessTo = [];
        forwardRules.dmz = ds {
          daddr = trista;
          tcp.dport = 22;
          verdict = "accept";
          comment = "wg-ba -> trista SSH";
        };
        inputRules = [];
      };

      isolated = {
        # No forwarding, no router services (available for future use)
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };

      media = {
        # Consumer media access: Jellyfin, Navidrome, Retrom (future game streaming)
        # Authenticated via WireGuard — only keyed devices reach this zone
        icmpEcho = "enable";
        accessTo = [];
        # oracion routed via transit since Phase 5.A — it lives in APP on
        # BT8-gateway, no longer in thebeyond-local DMZ. BT8-gateway's fw4
        # gates the transit→app side of the same flow.
        forwardRules.transit = ds {
          daddr = oracion;
          tcp.dport = 443;
          verdict = "accept";
          comment = "media -> oracion (Jellyfin/Navidrome/Retrom) [via BT8-gateway]";
        };
        inputRules = [
          {
            udp.dport = 53;
            verdict = "accept";
            comment = "DNS";
          }
        ];
      };

      wg-vpn = {
        # Authenticated VPN-in for operator devices (laptop, mobile). Pre-Phase-3
        # this zone was "lab" (admin/dev access to lab hosts + management
        # services). Post-Phase-3 those destinations are bt8gw-side, so reach is
        # via transit (cross-gateway) plus the thebeyond-resident dmz + external.
        icmpEcho = "enable";
        accessTo = ["dmz" "external" "transit"];
        inputRules = [
          {
            verdict = "accept";
            comment = "Full router service access";
          }
        ];
      };

      # APP services VLAN. Defined here so cross-zone references can name it,
      # but no interface on thebeyond binds to this zone — APP terminates on
      # BT8-gateway. Zone gets activated when services migrate in Phase 5.
      app = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };

      # Transit (point-to-point /30 + /64 to BT8-gateway). Entry point for
      # ALL office-side traffic destined for thebeyond-resident zones (DMZ,
      # external/NAT, ba-tunnel). Source-zone attribution is lost across the
      # gateway split: BT8-gateway's fw4 is the source-zone enforcer; transit
      # gates by destination + source subnet/host only.
      transit = {
        icmpEcho = "enable";
        accessTo = ["external" "ba-tunnel"];
        # DNS inputRules double as the kresd-on-transit binding signal —
        # `dnsInterfaces` in router6/lib.nix auto-binds kresd to any interface
        # in a zone whose inputRules allow DNS. No separate listen config.
        inputRules =
          [
            {
              udp.dport = 53;
              limit = "100/second";
              verdict = "accept";
              comment = "DNS";
            }
            {
              tcp.dport = 53;
              limit = "100/second";
              verdict = "accept";
              comment = "DNS over TCP";
            }
            {
              udp.dport = 123;
              verdict = "accept";
              comment = "NTP";
            }
          ]
          # Migrated admin VLANs (mgmt 11, trusted 20, lab 21) lost their
          # local bridges on thebeyond — their L3 terminates on BT8-gateway
          # and return traffic enters here. Pre-Phase-3 those zones had
          # inputRules=accept; this restores the same posture across the
          # gateway split, gated by source subnet (source-zone attribution
          # is lost across transit).
          ++ (ds {
            saddr = {
              ipv4 = [
                net.networks.management.subnet4
                net.networks.trusted.subnet4
                net.networks.lab.subnet4
              ];
              ipv6 = [
                net.networks.management.subnet6
                net.networks.trusted.subnet6
                net.networks.lab.subnet6
              ];
            };
            verdict = "accept";
            comment = "admin VLANs -> thebeyond input via BT8-gateway";
          });

        # Mirrors of cross-zone DMZ flows that used to be enforced inside
        # thebeyond before office-side gateways move to BT8-gateway. Source
        # restrictions defend against a compromised BT8-gateway impersonating
        # other zones (source-zone attribution is lost across the gateway
        # split — subnet/host IP is the strongest constraint available).
        forwardRules.dmz =
          # lab → dmz (broad) — mirrors current `lab.accessTo = [..."dmz"...]`
          (ds {
            saddr = {
              ipv4 = net.networks.lab.subnet4;
              ipv6 = net.networks.lab.subnet6;
            };
            verdict = "accept";
            comment = "lab -> dmz (any) [via BT8-gateway]";
          })
          # management → dmz:9100 (tharbad Prometheus node_exporter scrape)
          ++ (ds {
            saddr = tharbad;
            tcp.dport = 9100;
            verdict = "accept";
            comment = "tharbad -> dmz (node_exporter) [via BT8-gateway]";
          });

        # Admin access to network-zone hosts. Network zone otherwise denies
        # all forwards from admin VLANs by design (bt8bridge, phantasma,
        # arseille all live here); these are per-host carve-outs for the
        # mgmt path across the gateway split.
        forwardRules.network =
          (ds {
            saddr = {
              ipv4 = [
                net.networks.management.subnet4
                net.networks.trusted.subnet4
                net.networks.lab.subnet4
              ];
              ipv6 = [
                net.networks.management.subnet6
                net.networks.trusted.subnet6
                net.networks.lab.subnet6
              ];
            };
            daddr = bt8bridge;
            tcp.dport = [22 80 443];
            verdict = "accept";
            comment = "admin VLANs -> bt8bridge (SSH + LuCI) — narrow LuCI to operator allowlist after Phase 4.5";
          })
          ++ (ds {
            saddr = {
              ipv4 = [
                net.networks.management.subnet4
                net.networks.trusted.subnet4
                net.networks.lab.subnet4
              ];
              ipv6 = [
                net.networks.management.subnet6
                net.networks.trusted.subnet6
                net.networks.lab.subnet6
              ];
            };
            daddr = phantasma;
            tcp.dport = 22;
            verdict = "accept";
            comment = "admin VLANs -> phantasma (SSH) via BT8-gateway";
          });

        # trusted → untrusted (covers iot/adu/game which all bind into the
        # `untrusted` zone on thebeyond via subnetBindings). When Home
        # Assistant lands and a tighter iot-specific rule is wanted, split
        # the iot VLAN into its own router6 zone first; until then the broad
        # trusted → untrusted accept covers the HA access case too.
        forwardRules.untrusted = ds {
          saddr = {
            ipv4 = net.networks.trusted.subnet4;
            ipv6 = net.networks.trusted.subnet6;
          };
          verdict = "accept";
          comment = "trusted -> untrusted (any) [via BT8-gateway]";
        };
      };
    };

    # Cross-gateway static routes. BT8-gateway terminates APP/50 and any
    # office-side trusted VLANs migrated to it (Phase 3). The bt8gw-owned
    # IP space lives under 10.97.0.0/16 + fdc6:55f2:0a5e:1000::/52; the
    # transit /30 + /64 is the only point-to-point link to it. Connected
    # routes via the still-present bridges cover return traffic today;
    # these routes survive Phase 3 when those bridges are removed.
    routes = [
      {
        destination = "10.97.0.0/16";
        gateway = "10.255.255.2";
        interface = "brTRANSIT";
      }
      {
        destination = "fdc6:55f2:0a5e:1000::/52";
        gateway = "fdc6:55f2:0a5e:ffff::2";
        interface = "brTRANSIT";
      }
    ];

    dns = {
      upstream = [phantasma.ipv4]; # phantasma microVM on brMGMT (10.91.10.10)
      localDomain = "internal";
      enableDNSSEC = true;
      # phantasma's Unbound is the authoritative DNSSEC validator in this
      # deployment, reached over brMGMT (switched/wired bridge inside
      # thebeyond — trusted L2). Skip kresd-side re-validation on the
      # primary path; the fallback path stays on FORWARD (default) so kresd
      # locally re-validates anything coming back from the ISP resolver.
      upstreamPolicy = "stub";
      fallbackFromLease = "enp4s0";
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
          udp.dport = [38506 59362 51820];
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
        # WAN interface — DHCP from ISP.
        # Topology key is the kernel predictable name; no .link rename (see
        # file header note on hardwareName semantics).
        enp4s0 = {
          kind = "physical";
          network = {
            type = "dhcp";
            zone = "external";
            nat.enable = true;
            defaultRoute = true;
            ipv6PrefixDelegation = {
              enable = true;
              prefixLength = 56;
            };
          };
        };

        # Wired link to BT8-bridge — batman-adv hard interface.
        # mtu=1536 provides headroom for the ~25-byte batman encapsulation.
        # Topology key is the kernel predictable name; no .link rename.
        enp2s0 = {
          kind = "physical";
          network = {
            type = "disabled";
            mtu = 1536;
          };
        };

        # Batman-adv mesh device — single hard interface (wired to BT8-bridge)
        bat0 = {
          kind = "batman";
          members = ["enp2s0"];
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
              "${wg."wg-ba".gateway4}/24"
              "${wg."wg-ba".gateway6}/64"
            ];
            zone = "ba-tunnel";
            required = false;
          };
          wireguard = {
            privateKeyFile = config.sops.secrets."wg-ba-privatekey".path;
            port = 38506;
            openFirewall = true;
            peers = [
              {
                publicKey = "O+WWPlhy6Lg9YT3hYqq+/8gZ48PpRXaUTl4eFFwgTVA=";
                allowedIPs = let h = wg."wg-ba".hosts.remote; in [h.cidr4 h.cidr6];
                persistentKeepalive = 25;
              }
            ];
          };
        };

        # WireGuard - VPN for mobile devices
        "wg-vpn" = {
          kind = "wireguard";
          network = {
            type = "static";
            addresses = [
              "${wg."wg-vpn".gateway4}/24"
              "${wg."wg-vpn".gateway6}/64"
            ];
            zone = "wg-vpn";
            required = false;
          };
          wireguard = {
            privateKeyFile = config.sops.secrets."wg-vpn-privatekey".path;
            port = 59362;
            openFirewall = true;
            peers = [
              {
                publicKey = "sqPuQAWAKJzTice+L2kedo9X7Hx5WsMT/A6QXJVL/nA=";
                allowedIPs = let h = wg."wg-vpn".hosts.laptop; in [h.cidr4 h.cidr6];
              }
              {
                publicKey = "8g4r9czA23tS/XTOajuIa/BNfDE2x4GwdXXi+udE6gY=";
                allowedIPs = let h = wg."wg-vpn".hosts.mobile; in [h.cidr4 h.cidr6];
              }
            ];
          };
        };

        # WireGuard - media consumer access (Steam Deck, etc.)
        "wg-media" = {
          kind = "wireguard";
          network = {
            type = "static";
            addresses = [
              "${wg."wg-media".gateway4}/24"
              "${wg."wg-media".gateway6}/64"
            ];
            zone = "media";
            required = false;
          };
          wireguard = {
            privateKeyFile = config.sops.secrets."wg-media-privatekey".path;
            port = 51820;
            openFirewall = true;
            peers = [
              {
                publicKey = "dB9PoHBScKhwWtJpZztxOLDCC6faUdKbCsy8M0iQKzU=";
                allowedIPs = let h = wg."wg-media".hosts.arcus; in [h.cidr4 h.cidr6];
              }
            ];
          };
        };
      }
      // allBridges;
  };

  # Bridge microVM tap interfaces.
  # vm-10-* taps (network zone, e.g. phantasma) → brMGMT
  systemd.network.networks."10-vm-network" = {
    matchConfig.Name = "vm-10-*";
    networkConfig = {
      Bridge = "brMGMT";
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

  # Force /var/lib/private to mode 0700 — systemd's StateDirectory+DynamicUser
  # creates it with 0700 on first use and refuses to start the service if it
  # finds it with any other mode. impermanence bind-mounts /var/lib/private/kea
  # as the persistent target, but the parent /var/lib/private gets created at
  # the default 0755 along the way. This tmpfiles rule reconciles them on every
  # boot before any DynamicUser service tries to claim the directory.
  systemd.tmpfiles.rules = [
    "d /var/lib/private 0700 root root - -"
  ];
}
