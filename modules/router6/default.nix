{ config, options, pkgs, lib, ... }:

# Modern NixOS Router Module
# Uses: Kea (DHCP4/6), kresd (DNS), nftables (firewall), systemd-networkd (interfaces)
#
# Design principles:
# - Topology-driven configuration (define interfaces, derive everything else)
# - IPv6-first with full dual-stack support
# - Debuggable firewall rules with clear comments
# - Minimal magic, explicit configuration

let
  cfg = config.router6;

  # Helper to flatten topology into a list of all network interfaces
  flattenTopology = let
    flattenInterface = name: iface:
      [{ inherit name; inherit (iface) network; isVlan = false; parent = null; }]
      ++ (lib.mapAttrsToList (vlanName: vlan: {
        name = vlanName;
        inherit (vlan) network;
        isVlan = true;
        parent = name;
        tag = vlan.tag;
      }) (iface.vlans or {}));
  in lib.flatten (lib.mapAttrsToList flattenInterface cfg.topology);

  # Get all interfaces matching a predicate
  interfacesWhere = pred: map (i: i.name) (filter pred flattenTopology);

  # Get interfaces by trust level
  interfacesWithTrust = trust:
    let trusts = if lib.isList trust then trust else [trust];
    in interfacesWhere (i: lib.elem (i.network.trust or null) trusts);

  # Get interfaces with DHCP server enabled
  dhcpServerInterfaces = interfacesWhere (i: i.network.dhcp.enable or false);

  # Get interfaces that need NAT
  natInterfaces = interfacesWhere (i: i.network.nat.enable or false);

  # Get the external/WAN interfaces
  externalInterfaces = interfacesWithTrust "external";

  # All internal interfaces (for forwarding)
  internalInterfaces = interfacesWithTrust ["management" "trusted" "untrusted"];

  # Trusted interfaces (can access router services)
  trustedInterfaces = interfacesWithTrust ["management" "trusted"];

  inherit (lib) mkOption mkEnableOption types mkIf mkMerge optional optionals
    mapAttrs mapAttrsToList filterAttrs concatMapAttrs optionalAttrs optionalString
    concatStringsSep flatten filter elem;
  inherit (builtins) attrNames attrValues hasAttr length head elemAt;

in {
  options.router6 = {
    enable = mkEnableOption "IPv6-ready router service";

    ulaPrefix = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        ULA /48 prefix for internal IPv6 addressing.
        When set, IPv6 addresses are automatically generated for VLANs
        based on their VLAN tag (e.g., VLAN 10 -> prefix:a::/64).
      '';
      example = "fdc6:55f2:0a5e::/48";
    };

    topology = mkOption {
      description = "Network topology definition";
      default = {};
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          # Interface identification (one of these required for physical interfaces)
          mac = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "MAC address to match for interface renaming";
            example = "00:11:22:33:44:55";
          };

          hardwareName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Original hardware interface name";
            example = "enp0s3";
          };

          # Network configuration
          network = mkOption {
            type = types.submodule {
              options = {
                type = mkOption {
                  type = types.enum ["disabled" "dhcp" "static" "pppoe"];
                  default = "disabled";
                  description = ''
                    Network type:
                    - disabled: Interface exists but has no IP configuration
                    - dhcp: Get address via DHCP (typically WAN)
                    - static: Static IP address(es)
                    - pppoe: PPPoE connection (for DSL/fiber)
                  '';
                };

                addresses = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "Static IPv4/IPv6 addresses in CIDR notation";
                  example = ["10.0.10.1/24" "fd00:10::1/64"];
                };

                gateway = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Default gateway (for static WAN)";
                };

                dns = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "DNS servers (for static WAN)";
                };

                trust = mkOption {
                  type = types.nullOr (types.enum [
                    "external"    # WAN - untrusted, NAT source
                    "management"  # Admin access, full router access
                    "trusted"     # Can access other internal networks
                    "untrusted"   # Internet only, isolated from other networks
                    "isolated"    # No internet, no internal access
                  ]);
                  default = null;
                  description = "Trust level for firewall rules";
                };

                nat = mkOption {
                  type = types.submodule {
                    options.enable = mkEnableOption "NAT/masquerade on this interface";
                  };
                  default = {};
                };

                defaultRoute = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Use this interface for the default route";
                };

                dhcp = mkOption {
                  description = "DHCP server configuration for this interface";
                  type = types.submodule {
                    options = {
                      enable = mkEnableOption "DHCP server on this interface";

                      poolStart = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Start of DHCP pool (default: .100)";
                      };

                      poolEnd = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "End of DHCP pool (default: .200)";
                      };

                      reservations = mkOption {
                        type = types.listOf (types.submodule {
                          options = {
                            mac = mkOption { type = types.str; };
                            ip = mkOption { type = types.str; };
                            hostname = mkOption {
                              type = types.nullOr types.str;
                              default = null;
                            };
                          };
                        });
                        default = [];
                        description = "Static DHCP reservations";
                      };
                    };
                  };
                  default = {};
                };

                dhcp6 = mkOption {
                  description = "DHCPv6/SLAAC configuration";
                  type = types.submodule {
                    options = {
                      enable = mkEnableOption "DHCPv6 server / RA on this interface";
                      mode = mkOption {
                        type = types.enum ["slaac" "stateful" "stateless"];
                        default = "slaac";
                        description = "IPv6 address assignment mode";
                      };
                    };
                  };
                  default = {};
                };

                mtu = mkOption {
                  type = types.nullOr types.int;
                  default = null;
                  description = "Override interface MTU";
                };

                required = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Whether this interface is required for boot";
                };
              };
            };
            default = { type = "disabled"; };
          };

          # VLAN configuration
          vlans = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                tag = mkOption {
                  type = types.int;
                  description = "VLAN ID (1-4094)";
                };
                network = mkOption {
                  # Same as parent network option
                  type = types.submodule {
                    options = {
                      type = mkOption {
                        type = types.enum ["disabled" "static"];
                        default = "static";
                      };
                      addresses = mkOption {
                        type = types.listOf types.str;
                        default = [];
                      };
                      trust = mkOption {
                        type = types.nullOr (types.enum [
                          "external" "management" "trusted" "untrusted" "isolated"
                        ]);
                        default = null;
                      };
                      nat = mkOption {
                        type = types.submodule {
                          options.enable = mkEnableOption "NAT";
                        };
                        default = {};
                      };
                      dhcp = mkOption {
                        type = types.submodule {
                          options = {
                            enable = mkEnableOption "DHCP server";
                            poolStart = mkOption { type = types.nullOr types.str; default = null; };
                            poolEnd = mkOption { type = types.nullOr types.str; default = null; };
                            reservations = mkOption {
                              type = types.listOf (types.submodule {
                                options = {
                                  mac = mkOption { type = types.str; };
                                  ip = mkOption { type = types.str; };
                                  hostname = mkOption { type = types.nullOr types.str; default = null; };
                                };
                              });
                              default = [];
                            };
                          };
                        };
                        default = {};
                      };
                      dhcp6 = mkOption {
                        type = types.submodule {
                          options = {
                            enable = mkEnableOption "DHCPv6/RA";
                            mode = mkOption {
                              type = types.enum ["slaac" "stateful" "stateless"];
                              default = "slaac";
                            };
                          };
                        };
                        default = {};
                      };
                      mtu = mkOption { type = types.nullOr types.int; default = null; };
                      required = mkOption { type = types.bool; default = true; };
                    };
                  };
                };
              };
            });
            default = {};
          };

          # Batman-adv mesh networking
          batman = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                gatewayMode = mkOption {
                  type = types.enum ["off" "client" "server"];
                  default = "off";
                };
                routingAlgorithm = mkOption {
                  type = types.enum ["batman-iv" "batman-v"];
                  default = "batman-v";
                };
              };
            });
            default = null;
            description = "Batman-adv mesh configuration (makes this a batadv interface)";
          };

          # Attach to batman device
          batmanDevice = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Batman-adv device to attach this interface to";
            example = "bat0";
          };

          # Wireguard configuration
          wireguard = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                privateKeyFile = mkOption {
                  type = types.path;
                  description = "Path to wireguard private key file";
                };
                port = mkOption {
                  type = types.nullOr types.port;
                  default = null;
                  description = "Listen port (required if accepting connections)";
                };
                peers = mkOption {
                  type = types.listOf (types.submodule {
                    options = {
                      publicKey = mkOption { type = types.str; };
                      allowedIPs = mkOption { type = types.listOf types.str; };
                      endpoint = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                      };
                      persistentKeepalive = mkOption {
                        type = types.nullOr types.int;
                        default = null;
                      };
                    };
                  });
                  default = [];
                };
                openFirewall = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Open firewall for wireguard port";
                };
              };
            });
            default = null;
          };
        };
      }));
    };

    dns = mkOption {
      type = types.submodule {
        options = {
          upstream = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Primary upstream DNS servers";
          };

          fallback = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Static fallback DNS servers (used if useDHCPFallback is false)";
          };

          useDHCPFallback = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Use DNS servers from DHCP (WAN) lease as fallback
              when primary upstream servers are unavailable.
            '';
          };

          localDomain = mkOption {
            type = types.nullOr types.str;
            default = "local";
            description = "Local domain for DHCP hostnames";
          };

          enableDNSSEC = mkOption {
            type = types.bool;
            default = true;
            description = "Enable DNSSEC validation";
          };
        };
      };
      default = {};
    };

    firewall = mkOption {
      type = types.submodule {
        options = {
          extraInputRules = mkOption {
            type = types.lines;
            default = "";
            description = "Extra nftables rules for input chain";
          };

          extraForwardRules = mkOption {
            type = types.lines;
            default = "";
            description = "Extra nftables rules for forward chain";
          };

          extraNatRules = mkOption {
            type = types.lines;
            default = "";
            description = "Extra nftables rules for NAT";
          };

          portForwards = mkOption {
            type = types.listOf (types.submodule {
              options = {
                proto = mkOption {
                  type = types.enum ["tcp" "udp" "both"];
                  default = "tcp";
                };
                sourcePort = mkOption { type = types.port; };
                destination = mkOption {
                  type = types.str;
                  description = "ip:port to forward to";
                };
                sourceInterface = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Limit to specific interface (default: all external)";
                };
              };
            });
            default = [];
            description = "Port forwarding rules (DNAT)";
          };
        };
      };
      default = {};
    };
  };

  config = mkIf cfg.enable (let
    # Parse CIDR address to get network info
    parseCIDR = addr: let
      parts = lib.splitString "/" addr;
      ip = head parts;
      prefix = lib.toInt (lib.elemAt parts 1);
      octets = lib.splitString "." ip;
      isV6 = lib.hasInfix ":" ip;
    in {
      inherit ip prefix isV6;
      # For IPv4, calculate network address and pool defaults
      networkAddr = if isV6 then null else
        let o = map lib.toInt octets;
        in "${toString (elemAt o 0)}.${toString (elemAt o 1)}.${toString (elemAt o 2)}.0";
      poolStart = if isV6 then null else
        "${elemAt octets 0}.${elemAt octets 1}.${elemAt octets 2}.100";
      poolEnd = if isV6 then null else
        "${elemAt octets 0}.${elemAt octets 1}.${elemAt octets 2}.200";
      gateway = ip; # Router is typically the gateway
    };

    # Get first IPv4 address from a list
    firstIPv4 = addrs:
      let v4 = filter (a: !(lib.hasInfix ":" a)) addrs;
      in if v4 == [] then null else head v4;

    # Get first IPv6 address from a list
    firstIPv6 = addrs:
      let v6 = filter (a: lib.hasInfix ":" a) addrs;
      in if v6 == [] then null else head v6;

    # Generate IPv6 address from ULA prefix and VLAN tag
    mkAutoIPv6 = vlanTag:
      if cfg.ulaPrefix != null then
        let
          basePrefix = lib.removeSuffix "::/48" cfg.ulaPrefix;
          vlanHex = lib.toLower (lib.toHexString vlanTag);
        in "${basePrefix}:${vlanHex}::1/64"
      else null;

    # Get effective addresses including auto-generated IPv6
    getEffectiveAddresses = iface:
      let
        explicit = iface.network.addresses or [];
        hasExplicitV6 = lib.any (a: lib.hasInfix ":" a) explicit;
        # Auto-generate IPv6 for VLANs with dhcp6 enabled if no explicit IPv6
        autoV6 = if !hasExplicitV6 && (iface.isVlan or false) && (iface.tag or null) != null
                    && (iface.network.dhcp6.enable or false)
                 then mkAutoIPv6 iface.tag
                 else null;
      in explicit ++ (optional (autoV6 != null) autoV6);

    # Interfaces that have dhcp6/RA enabled
    dhcp6Interfaces = filter (i: i.network.dhcp6.enable or false) flattenTopology;

    # Build Kea subnet4 config for an interface
    mkKeaSubnet4 = iface: let
      addr = firstIPv4 iface.network.addresses;
      parsed = if addr != null then parseCIDR addr else null;
      dhcpCfg = iface.network.dhcp;
    in if parsed == null then null else {
      subnet = "${parsed.networkAddr}/${toString parsed.prefix}";
      pools = [{
        pool = "${dhcpCfg.poolStart or parsed.poolStart} - ${dhcpCfg.poolEnd or parsed.poolEnd}";
      }];
      option-data = [
        { name = "routers"; data = parsed.gateway; }
        { name = "domain-name-servers"; data = parsed.gateway; }
      ] ++ optional (cfg.dns.localDomain != null) {
        name = "domain-name";
        data = cfg.dns.localDomain;
      };
      reservations = map (r: {
        hw-address = r.mac;
        ip-address = r.ip;
      } // optionalAttrs (r.hostname != null) {
        hostname = r.hostname;
      }) (dhcpCfg.reservations or []);
    };

    # Generate all Kea subnets
    keaSubnets = filter (x: x != null) (map mkKeaSubnet4
      (filter (i: i.network.dhcp.enable or false) flattenTopology));

    # Quote interface name for nftables
    quote = s: ''"${s}"'';
    quoteList = list: "{ ${concatStringsSep ", " (map quote list)} }";

  in mkMerge [
    # ===================
    # Basic System Config
    # ===================
    {
      boot.kernel.sysctl = {
        "net.ipv4.conf.all.forwarding" = true;
        "net.ipv6.conf.all.forwarding" = true;
        "net.ipv4.conf.default.rp_filter" = 1;
        "net.ipv4.conf.all.rp_filter" = 1;
        # Accept RAs on external interface even when forwarding
        "net.ipv6.conf.all.accept_ra" = 0;
        "net.ipv6.conf.default.accept_ra" = 0;
      } // lib.listToAttrs (map (iface: {
        name = "net.ipv6.conf.${iface}.accept_ra";
        value = 2;
      }) externalInterfaces);

      networking = {
        useDHCP = false;
        firewall.enable = false; # We use nftables directly
      };

      systemd.network.enable = true;
      services.resolved.enable = false; # We use kresd

      environment.systemPackages = with pkgs; [
        tcpdump
        conntrack-tools
        ethtool
        dig
      ];
    }

    # ========================
    # systemd-networkd: Links
    # ========================
    {
      systemd.network.links = lib.listToAttrs (filter (x: x != null) (
        mapAttrsToList (name: iface:
          if iface.mac != null then {
            name = "00-${name}";
            value = {
              matchConfig.MACAddress = iface.mac;
              matchConfig.Type = "ether";
              linkConfig.Name = name;
            };
          } else if iface.hardwareName != null then {
            name = "00-${name}";
            value = {
              matchConfig.OriginalName = iface.hardwareName;
              linkConfig.Name = name;
            };
          } else null
        ) cfg.topology
      ));
    }

    # ==========================
    # systemd-networkd: Netdevs
    # ==========================
    {
      systemd.network.netdevs = let
        # VLAN netdevs
        vlanDevs = concatMapAttrs (parentName: parent:
          mapAttrs (vlanName: vlan: {
            netdevConfig = {
              Name = vlanName;
              Kind = "vlan";
            };
            vlanConfig.Id = vlan.tag;
          }) (parent.vlans or {})
        ) cfg.topology;

        # Batman netdevs
        batmanDevs = filterAttrs (n: v: v != null) (mapAttrs (name: iface:
          if iface.batman != null then {
            netdevConfig = {
              Name = name;
              Kind = "batadv";
            };
            batmanAdvancedConfig = {
              GatewayMode = iface.batman.gatewayMode;
              RoutingAlgorithm = iface.batman.routingAlgorithm;
            };
          } else null
        ) cfg.topology);

        # Wireguard netdevs
        wgDevs = filterAttrs (n: v: v != null) (mapAttrs (name: iface:
          if iface.wireguard != null then {
            netdevConfig = {
              Name = name;
              Kind = "wireguard";
            };
            wireguardConfig = {
              PrivateKeyFile = iface.wireguard.privateKeyFile;
            } // optionalAttrs (iface.wireguard.port != null) {
              ListenPort = iface.wireguard.port;
            };
            wireguardPeers = map (peer: {
              wireguardPeerConfig = {
                PublicKey = peer.publicKey;
                AllowedIPs = peer.allowedIPs;
              } // optionalAttrs (peer.endpoint != null) {
                Endpoint = peer.endpoint;
              } // optionalAttrs (peer.persistentKeepalive != null) {
                PersistentKeepalive = peer.persistentKeepalive;
              };
            }) iface.wireguard.peers;
          } else null
        ) cfg.topology);

      in vlanDevs // batmanDevs // wgDevs;
    }

    # ============================
    # systemd-networkd: Networks
    # ============================
    {
      systemd.network.networks = let
        mkNetworkConfig = iface: network: ifaceData: let
          # Get effective addresses (including auto-generated IPv6)
          effectiveAddrs = if ifaceData != null then getEffectiveAddresses ifaceData else network.addresses or [];
          # Check if this interface should send Router Advertisements
          shouldSendRA = (network.dhcp6.enable or false) && network.type == "static";
          # Get IPv6 addresses for RA prefix configuration
          v6Addrs = filter (a: lib.hasInfix ":" a) effectiveAddrs;
        in {
          matchConfig.Name = iface;

          networkConfig = {
            DHCP = if network.type == "dhcp" then "yes" else "no";
            IPv6AcceptRA = network.type == "dhcp";
            LinkLocalAddressing =
              if network.type == "disabled" then "no"
              else if network.type == "dhcp" then "yes"
              else "ipv6";
          } // optionalAttrs (network.type == "dhcp" && network.defaultRoute) {
            DefaultRouteOnDevice = true;
          } // optionalAttrs (network.type == "static" && length effectiveAddrs > 0) {
            Address = effectiveAddrs;
          } // optionalAttrs (network.gateway != null) {
            Gateway = network.gateway;
          } // optionalAttrs (length (network.dns or []) > 0) {
            DNS = network.dns;
          } // optionalAttrs shouldSendRA {
            # Enable Router Advertisement on interfaces with dhcp6 enabled
            IPv6SendRA = true;
          };

          linkConfig = {
            RequiredForOnline = if network.required then "routable" else "no";
          } // optionalAttrs (network.mtu != null) {
            MTUBytes = toString network.mtu;
          };
        } // optionalAttrs (shouldSendRA && v6Addrs != []) {
          # IPv6 Router Advertisement configuration
          ipv6SendRAConfig = {
            # SLAAC mode: M=0 (no managed addresses), O=0 (no other config from DHCPv6)
            # Clients will auto-configure addresses from the advertised prefix
            Managed = false;
            OtherInformation = false;
            RouterLifetimeSec = 1800;
            # Advertise DNS server (the router itself)
            EmitDNS = true;
            DNS = "_link_local";
          };

          # Advertise the IPv6 prefix for SLAAC
          ipv6Prefixes = map (addr: let
            parsed = parseCIDR addr;
            # Extract the network prefix (e.g., fdc6:55f2:0a5e:a::1/64 -> fdc6:55f2:0a5e:a::/64)
            ipParts = lib.splitString "::" parsed.ip;
            networkPrefix = "${head ipParts}::/${toString parsed.prefix}";
          in {
            ipv6PrefixConfig = {
              Prefix = networkPrefix;
              PreferredLifetimeSec = 3600;
              ValidLifetimeSec = 7200;
            };
          }) v6Addrs;
        };

        # Physical/main interface networks
        mainNetworks = mapAttrs (name: iface: let
          ifaceData = lib.findFirst (i: i.name == name) null flattenTopology;
        in
          (mkNetworkConfig name iface.network ifaceData) // {
            # Add VLAN references
            vlan = attrNames (iface.vlans or {});
          } // optionalAttrs (iface.batmanDevice != null) {
            networkConfig.BatmanAdvanced = iface.batmanDevice;
          }
        ) cfg.topology;

        # VLAN networks
        vlanNetworks = concatMapAttrs (parentName: parent:
          mapAttrs (vlanName: vlan: let
            ifaceData = lib.findFirst (i: i.name == vlanName) null flattenTopology;
          in
            mkNetworkConfig vlanName vlan.network ifaceData
          ) (parent.vlans or {})
        ) cfg.topology;

      in mainNetworks // vlanNetworks;
    }

    # ===================
    # Kea DHCP4 Server
    # ===================
    (mkIf (keaSubnets != []) {
      services.kea.dhcp4 = {
        enable = true;
        settings = {
          interfaces-config = {
            interfaces = dhcpServerInterfaces;
            dhcp-socket-type = "raw";
          };

          lease-database = {
            type = "memfile";
            persist = true;
            name = "/var/lib/kea/dhcp4.leases";
          };

          valid-lifetime = 7200;
          renew-timer = 1800;
          rebind-timer = 3600;

          subnet4 = keaSubnets;

          # Enable hostname updates to DNS
          ddns-send-updates = false; # kresd handles local DNS differently

          option-def = [];

          loggers = [{
            name = "kea-dhcp4";
            output_options = [{ output = "syslog"; }];
            severity = "INFO";
          }];
        };
      };
    })

    # ===================
    # kresd DNS Server
    # ===================
    {
      services.kresd = {
        enable = true;
        listenPlain = [
          "127.0.0.1:53"
          "[::1]:53"
        ] ++ (flatten (map (iface:
          let
            ifaceData = lib.findFirst (i: i.name == iface) null flattenTopology;
            addrs = if ifaceData != null then getEffectiveAddresses ifaceData else [];
            v4 = firstIPv4 addrs;
            v6 = firstIPv6 addrs;
          in
            (optional (v4 != null) "${(parseCIDR v4).ip}:53")
            ++ (optional (v6 != null) "[${(parseCIDR v6).ip}]:53")
        ) (trustedInterfaces ++ interfacesWithTrust "untrusted")));

        extraConfig = let
          primaryServers = concatStringsSep ", " (map (s: "'${s}'") cfg.dns.upstream);
          staticFallback = concatStringsSep ", " (map (s: "'${s}'") cfg.dns.fallback);
          hasStaticFallback = cfg.dns.fallback != [] && cfg.dns.fallback != cfg.dns.upstream;
          hasPrimary = cfg.dns.upstream != [];
          useDHCP = cfg.dns.useDHCPFallback;
        in ''
          modules.load('policy')

          ${optionalString (hasPrimary && (useDHCP || hasStaticFallback)) ''
          -- Primary DNS with fallback support
          local primary_failures = 0
          local last_primary_success = os.time()
          local primary_down = false
          local PRIMARY_THRESHOLD = 3      -- failures before switching
          local PRIMARY_RETRY = 30         -- seconds before retrying primary

          local primary = policy.FORWARD({${primaryServers}})

          -- Read DHCP-provided DNS servers from lease file
          local function get_dhcp_dns()
            local servers = {}
            local f = io.open('/run/kresd/dhcp-dns', 'r')
            if f then
              for line in f:lines() do
                local ip = line:match('^%s*(.-)%s*$')  -- trim whitespace
                if ip and ip ~= "" then
                  table.insert(servers, ip)
                end
              end
              f:close()
            end
            return servers
          end

          local function get_fallback()
            ${if useDHCP then ''
            local dhcp_servers = get_dhcp_dns()
            if #dhcp_servers > 0 then
              return policy.FORWARD(dhcp_servers)
            end
            '' else ""}
            ${if hasStaticFallback then ''
            return policy.FORWARD({${staticFallback}})
            '' else ''
            return nil
            ''}
          end

          policy.add(function(state, req)
            -- If primary is marked down, check if we should retry
            if primary_down then
              if os.time() - last_primary_success > PRIMARY_RETRY then
                primary_down = false
                primary_failures = 0
              else
                local fb = get_fallback()
                if fb then return fb(state, req) end
              end
            end

            -- Try primary
            local result = primary(state, req)
            if result then
              last_primary_success = os.time()
              primary_failures = 0
              return result
            else
              primary_failures = primary_failures + 1
              if primary_failures >= PRIMARY_THRESHOLD then
                primary_down = true
                log('[dns] Primary DNS unavailable, switching to fallback')
              end
              local fb = get_fallback()
              if fb then return fb(state, req) end
            end
          end)
          ''}

          ${optionalString (hasPrimary && !useDHCP && !hasStaticFallback) ''
          -- Upstream DNS servers (no fallback configured)
          policy.add(policy.all(policy.FORWARD({${primaryServers}})))
          ''}

          ${optionalString (!hasPrimary && useDHCP) ''
          -- Use DHCP-provided DNS only
          local function get_dhcp_dns()
            local servers = {}
            local f = io.open('/run/kresd/dhcp-dns', 'r')
            if f then
              for line in f:lines() do
                local ip = line:match('^%s*(.-)%s*$')
                if ip and ip ~= "" then
                  table.insert(servers, ip)
                end
              end
              f:close()
            end
            return servers
          end

          policy.add(function(state, req)
            local servers = get_dhcp_dns()
            if #servers > 0 then
              return policy.FORWARD(servers)(state, req)
            end
          end)
          ''}

          ${optionalString (cfg.dns.localDomain != null) ''
          -- Block external resolution of local domain
          policy.add(policy.suffix(policy.DENY, policy.todnames({'${cfg.dns.localDomain}.'})))
          ''}

          -- DNSSEC
          ${if cfg.dns.enableDNSSEC then ''
          trust_anchors.add_file('/var/lib/knot-resolver/root.keys')
          '' else ''
          trust_anchors.negative = { '.' }
          ''}

          -- Cache size (helps during outages)
          cache.size = 100 * MB
        '';
      };

      # Create directory for DHCP DNS file
      systemd.tmpfiles.rules = [
        "d /run/kresd 0755 knot-resolver knot-resolver -"
      ];

      # Service to extract DNS from DHCP lease and write to kresd-readable file
      systemd.services.kresd-dhcp-dns = mkIf cfg.dns.useDHCPFallback {
        description = "Extract DNS servers from DHCP lease for kresd";
        after = [ "systemd-networkd.service" ];
        wantedBy = [ "multi-user.target" ];

        # Run when network changes
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = let
            script = pkgs.writeShellScript "kresd-dhcp-dns" ''
              set -euo pipefail
              mkdir -p /run/kresd
              : > /run/kresd/dhcp-dns.tmp

              # Look for lease files from DHCP interfaces
              for lease in /run/systemd/netif/leases/*; do
                [ -f "$lease" ] || continue
                # Extract DNS servers from lease
                ${pkgs.gnugrep}/bin/grep -E '^DNS=' "$lease" 2>/dev/null | \
                  ${pkgs.coreutils}/bin/cut -d= -f2 | \
                  ${pkgs.coreutils}/bin/tr ' ' '\n' >> /run/kresd/dhcp-dns.tmp || true
              done

              # Deduplicate and move to final location
              ${pkgs.coreutils}/bin/sort -u /run/kresd/dhcp-dns.tmp > /run/kresd/dhcp-dns
              rm -f /run/kresd/dhcp-dns.tmp

              # Log what we found
              if [ -s /run/kresd/dhcp-dns ]; then
                echo "DHCP DNS servers: $(${pkgs.coreutils}/bin/tr '\n' ' ' < /run/kresd/dhcp-dns)"
              else
                echo "No DHCP DNS servers found"
              fi
            '';
          in "${script}";
        };
      };

      # Trigger DNS extraction when network changes
      systemd.paths.kresd-dhcp-dns = mkIf cfg.dns.useDHCPFallback {
        description = "Watch for DHCP lease changes";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = "/run/systemd/netif/leases";
          Unit = "kresd-dhcp-dns.service";
        };
      };
    }

    # ===================
    # nftables Firewall
    # ===================
    {
      networking.nftables = {
        enable = true;
        ruleset = let
          extIfaces = if externalInterfaces == [] then "" else quoteList externalInterfaces;
          trustIfaces = if trustedInterfaces == [] then "" else quoteList trustedInterfaces;
          intIfaces = if internalInterfaces == [] then "" else quoteList internalInterfaces;
          natIfaces = if natInterfaces == [] then "" else quoteList natInterfaces;

          # Wireguard ports that need to be opened
          wgPorts = filter (p: p != null) (mapAttrsToList (name: iface:
            if iface.wireguard != null && iface.wireguard.openFirewall && iface.wireguard.port != null
            then iface.wireguard.port
            else null
          ) cfg.topology);

          # Port forwarding rules
          dnatRules = concatStringsSep "\n          " (map (pf: let
            protoMatch = if pf.proto == "both" then "meta l4proto { tcp, udp }"
                        else pf.proto;
            ifaceMatch = if pf.sourceInterface != null
                        then ''iifname "${pf.sourceInterface}"''
                        else if externalInterfaces != []
                        then "iifname ${extIfaces}"
                        else "";
          in ''${ifaceMatch} ${protoMatch} dport ${toString pf.sourcePort} dnat to ${pf.destination}'')
          cfg.firewall.portForwards);

          forwardDnatRules = concatStringsSep "\n          " (map (pf: let
            destParts = lib.splitString ":" pf.destination;
            destIP = head destParts;
            protoMatch = if pf.proto == "both" then "meta l4proto { tcp, udp }" else pf.proto;
          in ''${protoMatch} dport ${toString pf.sourcePort} ip daddr ${destIP} accept'')
          cfg.firewall.portForwards);

        in ''
          table inet filter {
            chain input {
              type filter hook input priority filter; policy drop;

              # Accept established/related
              ct state established,related accept

              # Accept loopback
              iifname "lo" accept

              # Accept essential ICMP/ICMPv6 from anywhere (required for network operation)
              # - destination-unreachable: connection handling
              # - packet-too-big (v6) / frag-needed (v4): Path MTU Discovery (critical)
              # - time-exceeded: traceroute, TTL expiry
              # - parameter-problem: malformed packet notification
              icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
              icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept

              # Accept Neighbor Discovery (required for IPv6 to function - like ARP for IPv4)
              icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept

              ${optionalString (internalInterfaces != []) ''
              # Accept echo (ping) only from internal networks (stealth mode for external)
              iifname ${intIfaces} icmp type { echo-request, echo-reply } accept
              iifname ${intIfaces} icmpv6 type { echo-request, echo-reply } accept
              ''}

              ${optionalString (trustedInterfaces != []) ''
              # Trusted networks can access all router services
              iifname ${trustIfaces} accept
              ''}

              ${optionalString (internalInterfaces != []) ''
              # Internal networks can access DNS and DHCP
              iifname ${intIfaces} udp dport { 53, 67, 547 } accept
              iifname ${intIfaces} tcp dport 53 accept
              ''}

              ${optionalString (wgPorts != []) ''
              # Wireguard ports
              udp dport { ${concatStringsSep ", " (map toString wgPorts)} } accept
              ''}

              ${cfg.firewall.extraInputRules}

              ${optionalString (externalInterfaces != []) ''
              # Drop everything else from external
              iifname ${extIfaces} drop
              ''}

              # Log and drop anything else
              # log prefix "INPUT DROP: " drop
            }

            chain forward {
              type filter hook forward priority filter; policy drop;

              # Accept established/related
              ct state established,related accept

              # Clamp MSS to path MTU
              tcp flags syn tcp option maxseg size set rt mtu

              ${optionalString (trustedInterfaces != [] && internalInterfaces != []) ''
              # Trusted can access all internal networks
              iifname ${trustIfaces} oifname ${intIfaces} accept
              ''}

              ${optionalString (internalInterfaces != [] && externalInterfaces != []) ''
              # Internal networks can access external (internet)
              iifname ${intIfaces} oifname ${extIfaces} accept
              ''}

              ${optionalString (cfg.firewall.portForwards != []) ''
              # Port forward destinations
              ${forwardDnatRules}
              ''}

              ${cfg.firewall.extraForwardRules}

              # Log and drop anything else
              # log prefix "FORWARD DROP: " drop
            }

            chain output {
              type filter hook output priority filter; policy accept;
            }
          }

          table ip nat {
            chain prerouting {
              type nat hook prerouting priority dstnat;

              ${optionalString (cfg.firewall.portForwards != []) ''
              # DNAT / Port forwarding
              ${dnatRules}
              ''}

              ${cfg.firewall.extraNatRules}
            }

            chain postrouting {
              type nat hook postrouting priority srcnat;

              ${optionalString (natInterfaces != []) ''
              # Masquerade outgoing traffic on NAT interfaces
              oifname ${natIfaces} masquerade
              ''}
            }
          }

          # IPv6 NAT table (empty - no NAT66 needed for internal-only IPv6)
          # ULA addresses are used for internal IPv6 communication only
          table ip6 nat {
            chain prerouting {
              type nat hook prerouting priority dstnat;
            }

            chain postrouting {
              type nat hook postrouting priority srcnat;
            }
          }
        '';
      };
    }

    # ===================
    # Assertions
    # ===================
    {
      assertions = [
        {
          assertion = externalInterfaces != [] || cfg.topology == {};
          message = "Router needs at least one external interface with trust = \"external\"";
        }
        {
          assertion = length externalInterfaces <= 1 || (lib.any (i: i.network.defaultRoute) (attrValues cfg.topology));
          message = "With multiple external interfaces, at least one must have defaultRoute = true";
        }
      ] ++ (mapAttrsToList (name: iface: {
        assertion = !(iface.wireguard.openFirewall or false) || (iface.wireguard.port or null) != null;
        message = "Wireguard interface ${name}: openFirewall requires port to be set";
      }) (filterAttrs (n: v: v.wireguard != null) cfg.topology));
    }
  ]);
}
