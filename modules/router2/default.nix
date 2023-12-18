{ config, options, pkgs, lib, utils, ... }:

# There were two main sources of inspiration for this configuration:
#   1. https://pavluk.org/blog/2022/01/26/nixos_router.html
#   2. https://francis.begyn.be/blog/nixos-home-router
# Thank you very much!
let
  cfg = config.router;
  opt = options.router;
  nw-lib = pkgs.mmell.lib.network;
in {
  options.router = let
    inherit (lib) types mkOption mkEnableOption;
    mkTopologyOpt = is-dynamic: let
      dynType = types.submodule {
        options.env = mkOption {
          type = types.str;
          description = "the environment variable to fetch the value from dynamically";
        };
      };
      mkDynamicOpt = base: if is-dynamic then mkOption (base // {
        type = types.either base.type dynType;
      }) else mkOption base;
    in mkOption {
      type = let
        # TODO: have multiple submodules declare their exact type expectations,
        #       and merge together
        networkConf = mkOption {
          type = types.submodule {
            options.type = mkOption {
              type = types.enum [ "none" "disabled" "dhcp" "static" ];
              example = "none";
              description = ''
                Type of network this is mean to configure.  Expects one of the following network types:
                { type = "none"; } # Don't generate a network file
                { type = "disabled"; } # Has a network file, but with everything disabled
                { type = "dhcp"; nat.enable = true; trust = trust-status; } # a network where we get a dhcp address assigned -- we don't route this
                { type = "static"; addresses = [{ address = "..."; gateway? = "..."; dns? = "..."; }]; trust = trust-status } # static ip network
              '';
            };
            # todo: infer required via a mkDefault that checks if type == disabled,none ; maybe if vlans,pppoe non-empty?
            options.required = mkOption {
              type = types.bool;
              example = false;
              description = "Whether or not this network is required for start-up";
              default = true;
            };
            options.trust = mkOption {
              type = types.nullOr (types.enum [ "management" "external" "trusted" "untrusted" "lockdown" "local-access" ]);
              example = "external";
              description = ''
                trust-status determines how the firewall should handle this interface

                management: Lock down access to just 'trusted' and 'management', but allow https communication for non-external
                external: Do not allow it to initiate any communications
                trusted: Is allowed to initiate communications with other internal and external services
                untrusted: Is allowed to initiate communications with external
                lockdown: No access, neither internal nor external
                local-access: Only allowed access to this device, no forwarding
              '';
              default = null;
            };
            options.dhcp = mkOption {
              type = types.submodule {
                options.enable = mkEnableOption "Enable DHCP on a static network";
              };
              default = {};
            };
            options.dns = mkOption {
              type = types.enum [ "upstream" "resolved" ];
              description = "DNS provider to use -- either use the configured upstream, or use systemd resolved";
              default = "upstream";
              example = "resolved";
            };
            # todo: {ipv4,ipv6}.addresses.*.{address,prefixLength}
            options.static-addresses = mkOption {
              type = types.listOf types.str;
              example = [ "192.168.1.100" ];
              default = [];
              description = "Addresses to use for a static network";
            };
            options.static-gateways = mkOption {
              type = types.listOf types.str;
              example = [ "192.168.1.1" ];
              default = [];
              description = "Gateways to use for a static network";
            };
            options.static-dns = mkOption {
              type = types.listOf types.str;
              example = [ "192.168.1.1" ];
              default = [];
              description = "DNS to use for a static network";
            };
            # TODO: we should combine this with the routes option, and move routes into network
            options.nat = mkOption {
              type = types.submodule {
                options.enable = mkEnableOption "Enable NAT for ipv4 on this dhcp interface";
              };
              example = { enable = true; };
              default = {};
              description = "NAT options for dhcp networks";
            };
            options.route = mkOption {
              type = types.nullOr (types.enum [ "default" ]);
              example = "default";
              description = "For a DHCP network, mark this as primary/default route";
              default = null;
            };
          };
          default = { type = "none"; required = false; };
          description = "configuration of the network corresponding to this device";
        };
        bridgeConf = mkOption {
          type = types.nullOr (types.submodule {
            options.devices = mkOption {
              type = types.listOf types.str;
            };
          });
          default = null;
          description = "configure this network with a bridge netdev";
        };
        routesConf = mkOption {
          type = types.listOf (types.submodule {
            options.gateway = mkOption {
              type = types.str;
              description = "Address of Gateway for Static Routes";
              example = "192.168.1.100";
            };
            options.destination = mkOption {
              type = types.str;
              description = "Address and prefix to route to the gateway";
              example = "10.0.0.0/24";
            };
          });
          description = "Static routes that correspond with this interface";
          example = [
            { gateway = "192.168.1.100"; destination = "10.0.0.0/24"; }
          ];
          default = [];
        };
        pppoeConf = mkOption {
          description = "configuration of the pppoe network on this device or vlan";
          type = types.attrsOf (types.submodule {
            options.userfile = mkOption {
              type = types.path;
              description = "A path of an options file that sets the name of the user";
            };
            options.network = networkConf;
          });
          default = {};
        };
        vlanConf = mkOption {
          description = "configuration of the vlan on this device";
          type = types.attrsOf (types.submodule {
            options.tag = mkOption {
              type = types.int;
              example = 123;
              description = "Tag to use for the vlan";
            };
            options.pppoe = pppoeConf;
            options.network = networkConf;
            options.routes = routesConf;
          });
          default = {};
        };
      in types.attrsOf (types.submodule {
        # TODO: rename to "MAC"
        options.device = mkOption {
          type = types.nullOr types.str;
          example = "00:11:22:33:44:55";
          description = "MAC address of the device, to create the name for";
          default = null;
        };
        options.bridge = bridgeConf;
        options.network = networkConf;
        options.vlans = vlanConf;
        options.pppoe = pppoeConf;
        options.routes = routesConf;
        options.mtu = mkOption {
          type = types.nullOr types.str;
          example = "1536";
          description = "override the default mtu of the device";
          default = null;
        };
        options.batmanDevice = mkOption {
          type = types.nullOr types.str;
          example = "bat0";
          description = "batman-advanced network this device should be associated with, if any";
          default = null;
        };
        options.batman = mkOption {
          type = types.nullOr (types.submodule {
            options.gatewayMode = mkOption {
              type = types.nullOr types.str;
              example = "off";
              description = "gateway mode of the batman device";
            };
            options.routingAlgorithm = mkOption {
              type = types.nullOr types.str;
              example = "batman-v";
              description = "routing algorithm of the batman device";
            };
          });
          description = "configuration of the batman device";
          default = null;
        };
        options.wireguard = mkOption {
          type = types.nullOr (types.submodule {
            options.privateKeyFile = mkOption {
              type = types.path;
              description = "path to the file containing the private key";
            };
            # TODO: move this to the network, where we can specify trust/etc to integrate with nat/firewalling
            options.address = mkOption {
              type = types.str;
              description = "IP address that will be assigned to the host in the network";
            };
            options.port = mkOption {
              type = types.nullOr types.int;
              description = "port to listen on";
              default = null;
            };
            options.peers = mkOption {
              type = types.listOf (types.submodule {
                options.allowedIps = mkOption {
                  type = types.nonEmptyListOf types.str;
                  description = ''
                      IP addresses to route to the peer

                      If you want to route all traffic to the peer,
                      (aka use the peer as a VPN) use [ "0.0.0.0/0" "::/0" ]
                    '';
                  example = [ "0.0.0.0/0" "::/0" ];
                };
                options.publicKey = mkOption {
                  type = types.str;
                  description = "public key for the peer";
                };
                options.endpoint = mkDynamicOpt {
                  type = types.nullOr types.str;
                  description = "endpoint for the peer, including port";
                  example = "example.com:45678";
                  default = null;
                };
                options.persistentKeepalive = mkOption {
                  type = types.nullOr types.int;
                  description = "persistent keepalive value for the peer";
                  example = 25;
                  default = null;
                };
                options.dynamicEndpointRefreshRestartSeconds = mkOption {
                  type = types.nullOr types.int;
                  description = "how long a handshake needs to stall out before it will be refreshed";
                  example = 135;
                  default = null;
                };
              });
              description = "wireguard peers";
              default = [];
            };
            options.openFirewall = mkOption {
              type = types.bool;
              description = "whether or not to allow inbound traffic on the port";
              default = false;
            };
          });
          default = null;
        };
      });
      default = {};
    };
  in {
    enable = mkEnableOption "Home Router Service";

    # TODO: this might be better suited as something tied to the overall topology?
    dns = mkOption {
      type = types.submodule {
        options.upstream = mkOption {
          type = types.nullOr types.str;
          example = "192.168.1.2";
          description = "the upstream dns server, if any";
          default = null;
        };
        options.dyndns = mkOption {
          type = types.submodule {
            options.enable = mkEnableOption "Use Dynamic DNS";
            options.protocol = mkOption {
              type = types.enum [ "namecheap" ];
              default = "namecheap";
              description = "dyndns protocol";
            };
            options.server = mkOption {
              type = types.str;
              default = "";
              description = "Server for Dynamic DNS";
            };
            options.iface = mkOption {
              type = types.nullOr types.str;
              default = null;
              description =
                "The interface to get the ip address from." +
                "If null, will try and infer if there is a single active external.";
            };
            options.hosts = mkOption {
              type = types.listOf types.str;
              default = [];
              description = "hosts to use Dynamic DNS with.  Use '@' for all";
            };
            options.renewPeriod = mkOption {
              type = types.str;
              default = "60m";
              description = "How often to check Dynamic DNS ip address";
            };
            options.username = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Username/host";
            };
            options.usernameFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "File containing username/host";
            };
            options.passwordFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Path to file containing password";
            };
          };
          default = {};
        };
      };
    };
    firewall = let
      src-tgt = _src: _tgt: _type: types.submodule {
        options."${_src}" = mkOption {
          type = types.nullOr _type;
          description = "Indicates access from";
          default = null;
        };
        options."${_tgt}" = mkOption {
          type = types.nullOr _type;
          description = "Inidicates access to";
          default = null;
        };
      };
      firewall-extras = types.submodule {
        options.ip = mkOption {
          type = src-tgt "saddr" "daddr" types.str;
          default = {};
        };
        options.iifname = mkOption {
          type = types.nullOr (types.either types.str (types.nonEmptyListOf types.str));
          default = null;
        };
        options.oifname = mkOption {
          type = types.nullOr (types.either types.str (types.nonEmptyListOf types.str));
          default = null;
        };
        options.tcp = mkOption {
          type = src-tgt "sport" "dport" types.str;
          default = {};
        };
        options.udp = mkOption {
          type = src-tgt "sport" "dport" types.str;
          default = {};
        };
        options.verdict = mkOption {
          type = types.nullOr (types.either (types.enum [ "accept" "drop" ]) (types.submodule {
            options.dnat = mkOption {
              type = types.str;
            };
          }));
          default = null;
          description = "what to do when the rule is matched";
        };
        options.masquerade = mkOption {
          type = types.bool;
          default = false;
        };
      };
    in mkOption {
      type = types.submodule {
        # todo: parameterize firewall-extras based on what verdicts, etc, are allowed
        options.extraInput = mkOption {
          type = types.listOf firewall-extras;
          example = [{ ip.src = "192.168.1.100"; ip.tgt = "10.0.0.1"; }];
          description = "Extra firewall forwarding rules";
          default = [];
        };
        options.extraForwards = mkOption {
          type = types.listOf firewall-extras;
          example = [{ ip.src = "192.168.1.100"; ip.tgt = "10.0.0.1"; }];
          description = "Extra firewall forwarding rules";
          default = [];
        };
        options.extraPreRoutes = mkOption {
          type = types.listOf firewall-extras;
          example = [{ ip.src = "192.168.1.100"; ip.tgt = "10.0.0.1"; }];
          description = "Extra firewall forwarding rules";
          default = [];
        };
        options.extraPostRoutes = mkOption {
          type = types.listOf firewall-extras;
          example = [{ ip.src = "192.168.1.100"; ip.tgt = "10.0.0.1"; }];
          description = "Extra firewall forwarding rules";
          default = [];
        };
      };
      description = "Extra firewall rules";
      default = {};
    };
    topology = mkTopologyOpt false;
    dynamic = mkOption {
      type = types.submodule {
        options.environmentFile = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        options.topology = mkTopologyOpt true;
      };
      default = {};
    };
  };

  config = let
    concatMapAttrsToList = pkgs.mmell.lib.attrsets.concatMapAttrsToList;
    whole-topology = cfg.topology // cfg.dynamic.topology;

    networksWhere' = topo: pred: let
      filter = name: { network, vlans ? {}, pppoe ? {}, ... }: (
        if pred network then { ${name} = network; } else {}
      ) // (
        lib.attrsets.concatMapAttrs filter vlans
      ) // (
        lib.attrsets.concatMapAttrs filter pppoe
      );
    in (lib.attrsets.concatMapAttrs filter topo);
    networksWhere = networksWhere' whole-topology;

    interfacesWhere' = topo: pred: builtins.attrNames (networksWhere' topo pred);
    interfacesWhere = interfacesWhere' whole-topology;
    interfacesWithTrust = tr: interfacesWhere ({ trust ? null, ... }:
      if builtins.isList tr then builtins.elem trust tr else trust == tr
    );
    interfaces' = topo: interfacesWhere' topo (nw: nw.type != "disabled");
    interfaces = interfaces' whole-topology;

    interfacesOfType = ty: interfacesWhere (nw: nw.type == ty);
    natInterfaces = interfacesWhere (nw: nw.nat.enable);

    pppoeNames = let
      fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (builtins.attrNames pppoe) ++ (concatMapAttrsToList fromTopo vlans);
    in concatMapAttrsToList fromTopo whole-topology;

    empty-netdev = {
      matchConfig = {};
      vlanConfig = {};
      macvlanConfig = {};
      vxlanConfig = {};
      tunnelConfig = {};
      fooOverUDPConfig = {};
      peerConfig = {};
      tunConfig = {};
      tapConfig = {};
      l2tpConfig = {};
      l2tpSessions = [];
      wireguardConfig = {};
      wireguardPeers = [];
      bondConfig = {};
      xfrmConfig = {};
      vrfConfig = {};
      batmanAdvancedConfig = {};
      extraConfig = "";
    };

    from-dynamic = v: if v ? "env" then v.env else v;

    empty-network = {
      matchConfig = {};
      linkConfig = {};
      networkConfig = {};
      address = [];
      gateway = [];
      dns = [];
      ntp = [];
      bridge = [];
      bond = [];
      vrf = [];
      vlan = [];
      macvlan = [];
      macvtap = [];
      vxlan = [];
      tunnel = [];
      xfrm = [];
      addresses = [];
      routingPolicyRules = [];
      routeConfig = [];
      dhcpV4Config = {};
      dhcpV6Config = {};
      dhcpPrefixDelegationConfig = {};
      ipv6AcceptRAConfig = {};
      dhcpServerConfig = {};
      ipv6SendRAConfig = {};
      ipv6Prefixes = [];
      ipv6RoutePrefixes = [];
      dhcpServerStaticLeases = [];
      bridgeConfig = {};
      bridgeFDBs = [];
      bridgeMDBs = [];
      lldpConfig = {};
      canConfig = {};
      ipoIBConfig = {};
      qdiscConfig = {};
      networkEmulatorConfig  = {};
      tokenBucketFilterConfig = {};
      pieConfig = {};
      flowQueuePIEConfig = {};
      stochasticFairBlueConfig = {};
      stochasticFairnessQueueingConfig = {};
      bfifoConfig = {};
      pfifoConfig = {};
      pfifoHeadDropConfig = {};
      pfifoFastConfig = {};
      cakeConfig = {};
      controlledDelayConfig = {};
      deficitRoundRobinSchedulerConfig = {};
      deficitRoundRobinSchedulerClassConfig = {};
      enhancedTransmissionSelectionConfig = {};
      genericRandomEarlyDetectionConfig = {};
      fairQueueingControlledDelayConfig = {};
      fairQueueingConfig = {};
      trivialLinkEqualizerConfig = {};
      hierarchyTokenBucketConfig = {};
      hierarchyTokenBucketClassConfig = {};
      heavyHitterFilterConfig = {};
      quickFairQueueingConfig = {};
      quickFairQueueingConfigClass = {};
      bridgeVLANs = [];
      extraConfig = "";
    };
    
    mkNetdevUnits = let
      fromVlan = name: {
        tag,
          ...
      }: {
        "01-${name}" = {
          netdevConfig.Name = name;
          netdevConfig.Kind = "vlan";
          vlanConfig.Id = tag;
        };
      };
      fromWireguardPeer = {
        allowedIps,
          publicKey,
          endpoint ? null,
          persistentKeepalive ? null,
          ...
      }: {
        wireguardPeerConfig = lib.filterAttrs (n: v: v != null) {
          AllowedIPs = allowedIps;
          PublicKey = publicKey;
          Endpoint = from-dynamic endpoint;
          PersistentKeepalive = persistentKeepalive;
        };
      };
      fromWireguard = name: {
        privateKeyFile,
          port ? null,
          peers ? [],
          ...
      }: {
        "30-${name}" = {
          netdevConfig.Name = name;
          netdevConfig.Kind = "wireguard";
          wireguardConfig = lib.filterAttrs (n: v: v != null) {
            PrivateKeyFile = privateKeyFile;
            ListenPort = port;
          };
          wireguardPeers = builtins.map fromWireguardPeer peers;
        };
      };
    in
      name: {
        vlans ? {},
        batman ? null,
        wireguard ? null,
        bridge ? null,
        ...
      }: lib.attrsets.optionalAttrs (batman != null) ({
        "00-${name}" = {
          netdevConfig.Name = name;
          netdevConfig.Kind = "batadv";
          batmanAdvancedConfig = {
            GatewayMode = batman.gatewayMode;
            RoutingAlgorithm = batman.routingAlgorithm;
          };
        };
      }) // (
        lib.attrsets.concatMapAttrs fromVlan vlans
      ) // (
        lib.attrsets.optionalAttrs (bridge != null) {
          "02-${name}" = {
            netdevConfig.Kind = "bridge";
            netdevConfig.Name = name;
          };
        }
      ) // (
        lib.attrsets.optionalAttrs (wireguard != null) (fromWireguard name wireguard)
      );
    
    mkNetworkUnits = let
      mkNetworkConfig = {
        type,
          trust ? null,
          ignore-carrier ? false,
          route ? null,
          static-addresses ? [],
          static-gateways ? [],
          static-dns ? [],
          bridge-device ? null,
          ...
      }:
        let
          ignoreCarrier = lib.attrsets.optionalAttrs (ignore-carrier) {
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no"; # https://github.com/systemd/systemd/issues/9252#issuecomment-501850588
            IPv6AcceptRA=false; # https://bbs.archlinux.org/viewtopic.php?pid=1958133#p1958133
          };
          defRoute = lib.attrsets.optionalAttrs (route == "default") {
            DefaultRouteOnDevice = true;
          };
        in if type == "dhcp" then defRoute // {
          DHCP = "ipv4";
        } else if type == "disabled" then ignoreCarrier // {
          DHCP = "no";
          DHCPServer = false;
          LinkLocalAddressing = "no";
          LLMNR = false;
          MulticastDNS = false;
          LLDP = false;
          EmitLLDP = false;
          IPv6AcceptRA = false;
          IPv6SendRA = false;
        } else if type == "static" then ignoreCarrier // {
          Address = static-addresses;
          Gateway = static-gateways;
          DNS = static-dns;
          # multicast dns is provided by avahi
          # MulticastDNS = builtins.elem trust [ "trusted" "management" "untrusted" ];
        } else if type == "none" then null
          else abort "invalid type: ${type}";

      mkLinkConfig = { mtu, required, activation-status ? null }: (
        lib.attrsets.optionalAttrs (mtu != null) { MTUBytes = mtu; }
      ) // (
        lib.attrsets.optionalAttrs (!required) { RequiredForOnline = "no"; }
      ) // (
        lib.attrsets.optionalAttrs (activation-status != null) { ActivationPolicy = activation-status; }
      );
      mkRouteConfig = { gateway, destination, ... }: {
        routeConfig.Gateway = gateway;
        routeConfig.Destination = destination;
      };

      fromPppoe = name: {
        network,
          routes ? [],
          ...
      }: let
        nw-conf = mkNetworkConfig network;
      in lib.attrsets.optionalAttrs (nw-conf != null) {
        "22-${name}" = {
          matchConfig.Name = name;
          networkConfig = nw-conf // {
            KeepConfiguration = "static";
            LinkLocalAddressing = "no";
          };
          routes = builtins.map mkRouteConfig routes;
        };
      };

      fromVlan = name: {
        network,
          mtu ? null,
          pppoe ? {},
          routes ? [],
          ...
      }: {
        "21-${name}" = {
          matchConfig.Name = name;
          networkConfig = mkNetworkConfig network;
          linkConfig = mkLinkConfig { inherit mtu; inherit (network) required; };
          routes = builtins.map mkRouteConfig routes;
        };
      } // (
        lib.attrsets.concatMapAttrs fromPppoe pppoe
      );
    in
      name: {
        network,
        bridge ? null,
        vlans ? {},
        pppoe ? {},
        batmanDevice ? null,
        mtu ? null,
        routes ? [],
        wireguard ? null,
        ...
      }: let
        mkActivationStatus = { type, ignore-carrier ? false, ... }:
          if ignore-carrier then "always-up" else null;
        nw-conf = mkNetworkConfig network;
      in lib.attrsets.optionalAttrs (nw-conf != null) ({
        "${if wireguard == null then "10" else "40"}-${name}" = {
          matchConfig.Name = if bridge == null then name else bridge.devices;
          vlan = lib.attrsets.mapAttrsToList (name: vlan: name) vlans;
          networkConfig = nw-conf // (
            lib.attrsets.optionalAttrs (batmanDevice != null) { BatmanAdvanced = batmanDevice; }
          ) // (
            # If bridge is defined, then this network is attached to a bridge with the same name
            lib.attrsets.optionalAttrs (bridge != null) { Bridge = name; }
          );
          linkConfig = mkLinkConfig {
            inherit mtu;
            inherit (network) required;
            activation-status = (mkActivationStatus network);
          };
          routes = builtins.map mkRouteConfig routes;
        };
      } // (
        lib.attrsets.concatMapAttrs fromVlan vlans
      ) // (
        lib.attrsets.concatMapAttrs fromPppoe pppoe
      ));

    mkLinkUnits = name: {
      device ? null,
        mtu ? null,
        ...
    }: lib.attrsets.optionalAttrs (device != null) {
      "00-${name}" = {
        matchConfig.MACAddress = device;
        matchConfig.Type = "ether";
        linkConfig = {
          Name = name;
        } // (
          lib.attrsets.optionalAttrs (mtu != null) { MTUBytes = mtu; }
        );
      };
    };

    dynamic-netdevs = lib.attrsets.concatMapAttrs mkNetdevUnits cfg.dynamic.topology;
    dynamic-networks = lib.attrsets.concatMapAttrs mkNetworkUnits cfg.dynamic.topology;
    
  in lib.mkIf cfg.enable {
    assertions = lib.attrValues (
      lib.mapAttrs (name: value: {
        assertion = (value.wireguard != null && value.wireguard.openFirewall) -> (value.wireguard.port != null);
        message = "Cannot open the firewall for ${name} if no port is defined";
      }) whole-topology
    ) ++ lib.flatten (lib.attrValues (
      lib.mapAttrs (name: value: builtins.map (peer: {
        assertion = (peer.dynamicEndpointRefreshRestartSeconds != null) -> (peer.endpoint != null);
        message = "Cannot refresh the wireguard endpoint for ${name} and peer ${peer.publicKey} if no endpoint is defined";
      }) (if value.wireguard != null then value.wireguard.peers else [])) whole-topology
    )) ++ [{
      assertion = lib.lists.mutuallyExclusive (interfaces' cfg.topology) (interfaces' cfg.dynamic.topology);
      message = "Dynamic and Static interface names must be mutually exclusive";
    }];

    boot.kernel.sysctl = {
      "net.ipv4.conf.all.forwarding" = true;
      "net.ipv6.conf.all.forwarding" = true;

      # source: https://github.com/mdlayher/homelab/blob/master/nixos/routnerr-2/configuration.nix#L52
      "net.ipv6.conf.all.accept_ra" = 0;
      "net.ipv6.conf.all.autoconf" = 0;
      "net.ipv6.conf.all.use_tempaddr" = 0; 
    } // (lib.lists.foldr (nat: acc: {
      "net.ipv6.conf.${nat}.accept_ra" = 2;
      "net.ipv6.conf.${nat}.autoconf" = 1;
    } // acc) {} natInterfaces);

    environment.systemPackages = with pkgs; [
      vim
      htop
      ethtool
      tcpdump
      conntrack-tools
      batctl
      bind
    ];

    systemd.network.enable = true;
    services.resolved.enable = true;
    networking = {
      useDHCP = false;
      firewall.enable = false; # use custom nftables integration
      nameservers = builtins.filter (v: v != null) [ cfg.dns.upstream ]; # use upstream for the router dns as well
    };

    systemd.network = {
      links = lib.attrsets.concatMapAttrs mkLinkUnits cfg.topology;
      netdevs = lib.attrsets.concatMapAttrs mkNetdevUnits cfg.topology;
      networks = lib.attrsets.concatMapAttrs mkNetworkUnits cfg.topology;
    };

    # todo: should this make 1 service per dynamic device?
    systemd.services."router-network-dynamic" = lib.mkIf (
      cfg.dynamic.topology != {}
    ) (let
      volatilePath = "/run/systemd/network";
    in {
      wants = [ "network-pre.target" ];
      before = [ "network-pre.target" ];
      wantedBy = [ "network.target" ];
      path = with pkgs; [ bash envsubst ];
      script = with utils.systemdUtils.network; ''
        mkdir -p ${volatilePath}
        chown systemd-network:systemd-network ${volatilePath}

      '' + (lib.strings.concatStringsSep "\n" (
        lib.attrsets.mapAttrsToList (file: contents: ''
          envsubst <<EOF >${volatilePath}/${file}.netdev
          ${contents}
          EOF

          chown systemd-network:systemd-network ${volatilePath}/${file}.netdev
        '') (builtins.mapAttrs (name: nd: units.netdevToUnit (empty-netdev // nd)) dynamic-netdevs)
      )) + (lib.strings.concatStringsSep "\n" (
        lib.attrsets.mapAttrsToList (file: contents: ''
          envsubst <<EOF >${volatilePath}/${file}.network
          ${contents}
          EOF

          chown systemd-network:systemd-network ${volatilePath}/${file}.network
        '') (builtins.mapAttrs (name: nd: units.networkToUnit (empty-network // nd)) dynamic-networks)
      ));
      # todo: eventually have this remove the links via an (ip?) command -- networkd just kinda abandons them :/
      preStop = (lib.strings.concatStringsSep "\n" (
        lib.attrsets.mapAttrsToList (file: contents: ''
          rm ${volatilePath}/${file}.netdev
        '') dynamic-netdevs
      )) + (lib.strings.concatStringsSep "\n" (
        lib.attrsets.mapAttrsToList (file: contents: ''
          rm ${volatilePath}/${file}.network
        '') dynamic-networks
      ));
      serviceConfig.Type = "oneshot";
      serviceConfig.EnvironmentFile = cfg.dynamic.environmentFile;
      serviceConfig.RemainAfterExit = true;
    });

    systemd.services."router-wireguard-dynamic-endpoint-refresh" = let
      getWireguardConf = lib.attrsets.concatMapAttrs (name: { wireguard ? {}, vlans ? {}, pppoe ? {}, ... }:
        (
          getWireguardConf vlans
        ) // (
          getWireguardConf pppoe
        ) // (let
          peers-with-refresh = builtins.filter (p:
            p.dynamicEndpointRefreshRestartSeconds != null
          ) (wireguard.peers or []);
        in lib.attrsets.optionalAttrs (peers-with-refresh != []) {
          ${name} = wireguard // { peers = peers-with-refresh; };
        }));
      wireguard-confs = getWireguardConf whole-topology;
    in lib.mkIf (wireguard-confs != {}) {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ bash wireguard-tools ];
      script = lib.strings.concatStringsSep "\n" (
        concatMapAttrsToList (iface: {
          peers,
            ...
        }: builtins.map (peer: ''
          re=$'${builtins.replaceStrings ["+"] ["\\+"] peer.publicKey}\t([0-9]+)'
          if [[ $(wg show "${iface}" latest-handshakes) =~ $re ]]; then
            if (( ($EPOCHSECONDS - ''${BASH_REMATCH[1]}) > ${toString peer.dynamicEndpointRefreshRestartSeconds} )); then
              echo "Updating wg endpoint for iface ${iface} and peer ${peer.publicKey}"
              wg set "${iface}" peer "${peer.publicKey}" endpoint "${from-dynamic peer.endpoint}"
            fi
          fi
        '') peers) wireguard-confs
      );
      serviceConfig.Type = "oneshot";
      serviceConfig.EnvironmentFile = cfg.dynamic.environmentFile;
    };
    systemd.timers."router-wireguard-dynamic-endpoint-refresh" = lib.mkIf (config.systemd.services ? "router-wireguard-dynamic-endpoint-refresh") {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "5m";
        Unit = "router-wireguard-dynamic-endpoint-refresh.service";
      };
    };

    # TODO: make mtu setting based on the configured values of the pppoe device
    services.pppd = let
      mkConfig = parentDev: pppName: userfile: ''
        plugin pppoe.so ${parentDev}

        hide-password
        file ${userfile}

        # Settings sourced from https://blog.confirm.ch/using-pppoe-on-linux/

        # Connection settings.
        persist
        maxfail 0
        holdoff 5

        # LCP settings.
        lcp-echo-interval 10
        lcp-echo-failure 3

        # PPPoE compliant settings.
        noaccomp
        default-asyncmap
        mtu 1492

        # IP settings.
        noipdefault
        defaultroute

        # Linux only
        ifname ${pppName}
      '';
      fromPppoe = dev: name: pppoe:
        {
          inherit name;
          value = {
            enable = true;
            config = (mkConfig dev name pppoe.userfile);
          };
        };
      fromTopology = name: { vlans ? {}, pppoe ? {}, ...}:
        (concatMapAttrsToList (fromPppoe name) pppoe) ++ (concatMapAttrsToList fromTopology vlans);
      peers = builtins.listToAttrs (concatMapAttrsToList fromTopology cfg.topology);
    in {
      inherit peers;
      enable = peers != [];
    };

    services.kea = let
      dhcp4-networks = networksWhere (n: n.dhcp.enable);
    in {
      dhcp4.enable = dhcp4-networks != {};
      dhcp4.settings = {
        interfaces-config.interfaces = builtins.attrNames dhcp4-networks;
        valid-lifetime = 4000;
        renew-timer = 1000;
        rebind-timer = 2000;
        lease-database = {
          name = "/var/lib/kea/dhcp4.leases";
          persist = true;
          type = "memfile";
        };
        subnet4 = concatMapAttrsToList (name: nw: builtins.map (ipv4: {
          pools = let
            min = nw-lib.replace-ipv4 ["100"] ipv4;
            max = nw-lib.replace-ipv4 ["200"] ipv4;
          in [{
            pool = "${min} - ${max}";
          }];
          subnet = ipv4;
        }) nw.static-addresses) dhcp4-networks;
      };
    };

    services.kresd = {
      enable = true;
      listenPlain = [
        "127.0.0.1:53"
        "[::1]:53"
      ];
      # TODO: validate this mess
      extraConfig = lib.strings.concatStringsSep "\n" ([
        "modules.load('policy');"
      ] ++ lib.lists.flatten (lib.attrsets.mapAttrsToList (name: { static-addresses, ...}:
        builtins.map (addr: let
          fmt = (nw-lib.parsing.cidr4 gw).ipv4.formatted;
        in
          "view:addr(${fmt}/24, policy.all(policy.FORWARD(${cfg.dns.upstream})))"
        ) static-addresses
      ) (networksWhere (n: n.dns == "upstream"))) ++ [
        "policy:add(policy.all(policy.FORWARD('127.0.0.53')))";
      ]);
    };

    systemd.services."router-dyn-dns" = let
      dyndns = cfg.dns.dyndns;
      external = interfacesWhere ({route, trust, ...}: route == "default" && trust == "external");
      inferred-external =
        if builtins.length external == 1
        then builtins.head external
        else abort "Unable to infer which interface is external -- please specify";
      iface =
        if dyndns.iface != null
        then dyndns.iface
        else inferred-external;
    in lib.mkIf (dyndns.enable) {
      path = with pkgs; [ bash curl dig gnugrep iproute2 ];
      script = if dyndns.protocol == "namecheap" then (''
        DDNS_EXTERNAL_IP=$(ip -4 a show ${iface} | grep -Po 'inet \K[0-9.]*')
        DDNS_DOMAIN=${if dyndns.username != null then dyndns.username else ("$(cat " + dyndns.usernameFile + ")")}
        DDNS_PASSWORD=$(cat ${dyndns.passwordFile})
      '' + "\n" + lib.strings.concatStringsSep "\n" (builtins.map (host: ''
        DDNS_DOMAIN_IP=$(dig +short "${if host == "@" then "" else host + "."}$DDNS_DOMAIN") || DDNS_DOMAIN_IP=""

        if [ "$DDNS_EXTERNAL_IP" != "$DDNS_DOMAIN_IP" ]; then
          curl "${dyndns.server}/update?host=${host}&domain=$DDNS_DOMAIN&password=$DDNS_PASSWORD"
        fi
      '') dyndns.hosts)) else abort "Unknown protocol for dyndns: ${dyndns.protocol}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig.Type = "oneshot";
    };
    systemd.timers."router-dyn-dns" = lib.mkIf (config.systemd.services ? "router-dyn-dns") {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.dns.dyndns.renewPeriod;
        OnUnitActiveSec = cfg.dns.dyndns.renewPeriod;
        Unit = "router-dyn-dns.service";
      };
    };

    networking.nftables = let
      external = interfacesWithTrust "external";
      management = interfacesWithTrust "management";
      trusted = interfacesWithTrust [ "trusted" "management" ];
      untrusted = (interfacesWithTrust "untrusted");
      local-access = interfacesWithTrust "local-access";
      lockdown = interfacesWithTrust "lockdown";
      all-wan-access = trusted ++ untrusted;
      all-internal = all-wan-access ++ lockdown;

      render-chain-kind = { type, hook, device ? null, priority, default-policy, ... }:
        lib.strings.concatStringsSep " " (
          [ "type ${type} hook ${hook}"
          ] ++ (if device == null then [] else [ "device ${device}" ]
          ) ++ [ "priority ${priority}; policy ${default-policy};" ]
        );
      render-formatted-rule = let
        render-long-brackets = inner:
          if builtins.stringLength inner < 25
          then "{ ${inner} }"
          else lib.strings.concatStringsSep "\n    " [ "{" (indent inner) "}" ];
        render-match = match:
          if builtins.isString match then match
          else if builtins.isList match then render-long-brackets (lib.strings.concatStringsSep ", " match)
          else if builtins.hasAttr "not" match then "!= ${match.not}"
          else if builtins.hasAttr "vmap" match then "vmap " + (render-long-brackets (lib.strings.concatStringsSep ", " (
            lib.attrsets.mapAttrsToList (n: v: n + " : " + v) match.vmap
          )))
          else abort "invalid match rule: ${builtins.toString match}";
        render-sub-rule = proto: attr: set:
          if builtins.hasAttr attr set && builtins.getAttr attr set != null
          then [ "${proto} ${attr} ${render-match (builtins.getAttr attr set)}" ]
          else [];
        render-verdict = ver:
          if builtins.isString ver then ver
          else if builtins.hasAttr "dnat" ver then "dnat to ${ver.dnat}"
          else abort "invalid verdict: ${ver}";
        render-if-name = if-name: let
          quoted = if builtins.isString if-name then quote if-name else builtins.map quote if-name;
        in render-match quoted;
        quote = dev: "\"" + dev + "\"";
      in {
        iifname ? null, oifname ? null, tcp ? {}, udp ? {}, ip ? {}, counter ? false, ct ? {}, verdict ? null, masquerade ? false, comment ? null
      }: lib.strings.concatStringsSep " " (
        (
          if iifname == null then [] else [ "iifname ${render-if-name iifname}" ]
        ) ++ (
          render-sub-rule "tcp" "sport" tcp
        ) ++ (
          render-sub-rule "udp" "sport" udp
        ) ++ (
          render-sub-rule "ip" "saddr" ip
        ) ++ (
          if oifname == null then [] else [ "oifname ${render-if-name oifname}" ]
        ) ++ (
          render-sub-rule "tcp" "dport" tcp
        ) ++ (
          render-sub-rule "udp" "dport" udp
        ) ++ (
          render-sub-rule "ip" "daddr" ip
        ) ++ (
          render-sub-rule "ct" "state" ct
        ) ++ (
          if counter then [ "counter" ] else []
        ) ++ (
          if verdict == null then [] else [ (render-verdict verdict) ]
        ) ++ (
          if masquerade then [ "masquerade" ] else []
        ) ++ (
          if comment == null then [] else [ "comment \"${comment}\"" ]
        )
      );
      render-rule = rule: indent (
        if lib.isString rule then rule else render-formatted-rule rule
      );
      indent-n = n: v: if n == 0 then v else "  " + (indent-n (n - 1) v);
      indent = indent-n 1;
      render-rules = let
        folder = next: { rendered, pad-next }:
          if lib.strings.hasInfix "\n" next then { rendered = rendered ++ [ "" next ]; pad-next = true; }
          else if pad-next then { rendered = rendered ++ [ "" next ]; pad-next = false; }
          else { rendered = rendered ++ [next]; pad-next = false; };
      in kind: rules: (lib.lists.foldr folder { rendered = kind; pad-next = false; } (builtins.map render-rule rules)).rendered;
      render-chain = name: { kind ? null, rules ? [], ...}:
        let
          kind-rule =
            if kind == null then [] else [(indent (render-chain-kind kind))];
        in [
          "chain ${name} {"
        ] ++ (
          render-rules kind-rule (lib.lists.reverseList rules)
        ) ++ ["}"];
      render-table = family: name: { chains }:
        [
          "table ${family} ${name} {"
        ] ++ (
          builtins.map indent (
            lib.lists.flatten (
              lib.strings.intersperse "" (
                lib.lists.reverseList (
                  lib.attrsets.mapAttrsToList render-chain chains
                )
              )
            )
          )
        ) ++ ["}"];
      render-firewall-rules = fwall: lib.strings.concatStringsSep "\n" (
        lib.lists.flatten (
          lib.lists.flatten (
            lib.strings.intersperse "" (
              lib.attrsets.mapAttrsToList (
                name: value: lib.attrsets.mapAttrsToList (render-table name) value
              ) fwall
            )
          )
        )
      );
    in {
      enable = true;
      ruleset = render-firewall-rules {
        inet.filter = {
          chains = {
            "output" = {
              kind = {
                type = "filter"; # filter, route, nat
                hook = "output";
                # family == filter --> prerouting, input, forward, output, postrouting,
                # family == arp --> input, output
                # family == bridge --> ethernet packets?
                # family == netdev --> ingress
                priority = "100";
                default-policy = "accept"; # accept, drop
              };
            };
            "input" = {
              kind = {
                type = "filter";
                hook = "input";
                device = null;
                priority = "filter";
                default-policy = "drop";
              };
              rules = [
                {
                  iifname = trusted ++ local-access ++ [ "lo" ];
                  counter = true;
                  verdict = "accept";
                  comment = "Allow trusted networks to access the router";
                }
              ] ++ (if untrusted == [] then [] else [
                {
                  iifname = untrusted;
                  tcp.dport = [ "53" ];
                  counter = true;
                  verdict = "accept";
                  comment = "allow untrusted access to DNS and DHCP";
                }
                {
                  iifname = untrusted;
                  udp.dport = [ "53" "67" "mdns" ];
                  counter = true;
                  verdict = "accept";
                }
              ]) ++ (
                cfg.firewall.extraInput
              ) ++ (
                builtins.filter (v: v != null) (lib.attrValues (
                  lib.mapAttrs (name: value:
                    if (value.wireguard == null || !value.wireguard.openFirewall) then null else {
                      udp.dport = builtins.toString value.wireguard.port;
                      verdict = "accept";
                      comment = "Autogenerated for Wireguard interface ${name}";
                    }
                  ) whole-topology
                ))
              ) ++ (if external == [] then [] else [
                {
                  iifname = external;
                  ct.state = [ "established" "related" ];
                  counter = true;
                  verdict = "accept";
                }
                {
                  iifname = external;
                  verdict = "drop";
                }
              ]);
            };
            "forward" = {
              kind = {
                type = "filter";
                hook = "forward";
                device = null;
                priority = "filter";
                default-policy = "drop";
              };
              rules = [
                # todo: how should we handle this in the dsl?
                "tcp flags syn tcp option maxseg size set rt mtu"
              ] ++ (if all-wan-access == [] || external == [] then [] else [
                {
                  iifname = all-wan-access;
                  oifname = external;
                  counter = true;
                  verdict = "accept";
                  comment = "Allow all internal access to WAN";
                }
              ]) ++ (if trusted == [] then [] else [
                {
                  iifname = trusted;
                  oifname = all-internal;
                  counter = true;
                  verdict = "accept";
                  comment = "Allow trusted internal to all internal";
                }
              ]) ++ (if untrusted == [] && management == [] then [] else [
                {
                  iifname = untrusted ++ management;
                  oifname = untrusted ++ management;
                  tcp.dport = [ "http" "https" ];
                  counter = true;
                  verdict = "accept";
                  comment = "Allow untrusted access to internal management http(s)";
                }
              ]) ++ (
                cfg.firewall.extraForwards
              ) ++ [
                {
                  ct.state = [ "established" "related" ];
                  counter = true;
                  verdict = "accept";
                  comment = "Allow all established";
                }
              ];
            };
          };
        };
        ip.nat = {
          chains = {
            "prerouting" = {
              kind = {
                type = "nat";
                hook = "prerouting";
                priority = "-100";
                default-policy = "accept";
              };
              rules = cfg.firewall.extraPreRoutes;
            };
            "postrouting" = {
              kind = {
                type = "nat";
                hook = "postrouting";
                priority = "100";
                default-policy = "accept";
              };
              rules = (if natInterfaces == [] then [] else [
                {
                  oifname = natInterfaces;
                  masquerade = true;
                }
              ]) ++ cfg.firewall.extraPostRoutes;
            };
          };
        };
      };
    };
  };
}
