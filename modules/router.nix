{ config, options, pkgs, lib, utils, ... }:

# There were two main sources of inspiration for this configuration:
#   1. https://pavluk.org/blog/2022/01/26/nixos_router.html
#   2. https://francis.begyn.be/blog/nixos-home-router
# Thank you very much!
let
  cfg = config.router;
  opt = options.router;
in {
  options.router = with lib; let
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
              type = types.enum [ "self" "cloudflare" ];
              description = "DNS provider to use -- either use this router, or use cloudflare";
              default = "self";
              example = "cloudflare";
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
              type = types.nullOr (types.enum [ "primary" ]);
              example = "primary";
              description = "For a DHCP network, mark this as primary/default route";
              default = null;
            };
          };
          default = { type = "none"; required = false; };
          description = "configuration of the network corresponding to this device";
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
        options.device = mkOption {
          type = types.nullOr types.str;
          example = "00:11:22:33:44:55";
          description = "MAC address of the device, to create the name for";
          default = null;
        };
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
        # TODO: add an option that makes a unit do a periodic endpoint refresh with the following command:
        #       wg set "${interface}" peer "${publickey}" endpoint "${endpoint}"
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
          type = types.str; # types.nullOr types.str;
        };
        options.topology = mkTopologyOpt true;
      };
      default = {};
    };
  };

  config = let
    flatMapAttrsToList = f: v: lib.lists.flatten (lib.attrsets.mapAttrsToList f v);
    filterMap = f: l: builtins.filter (v: v != null) (builtins.map f l);
    attrKeys = lib.attrsets.mapAttrsToList (name: ignored: name);
    optional = cond: val: if cond then [val] else [];
    optNonNull = val: optional (val != null) val;
    liftNonNull = f: val: if val == null then null else f val;

    networksWhere = pred: let
      filter = name: { network, vlans ? {}, pppoe ? {}, ... }: (
        if pred network then { ${name} = network; } else {}
      ) // (
        lib.attrsets.concatMapAttrs filter vlans
      ) // (
        lib.attrsets.concatMapAttrs filter pppoe
      );
    in lib.attrsets.concatMapAttrs filter cfg.topology;
    interfacesWhere = pred: builtins.attrNames (networksWhere pred);

    interfacesWithTrust = tr: interfacesWhere ({ trust ? null, ... }: (if builtins.isList tr then builtins.elem trust tr else trust == tr));
    interfaces = interfacesWhere (nw: nw.type != "disabled");

    interfacesOfType = ty: interfacesWhere (nw: nw.type == ty);
    natInterfaces = interfacesWhere (nw: nw.nat.enable);

    pppoeNames = let
      fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (attrKeys pppoe) ++ (flatMapAttrsToList fromTopo vlans);
    in flatMapAttrsToList fromTopo cfg.topology;

    # should eventually return object like { ipv4: [...]; ipv6: [...]; }
    addrFirstN = n: addr: lib.strings.concatStringsSep "." (lib.lists.take n (lib.strings.splitString "." addr));
    addrNoPrefix = addr: builtins.head (lib.strings.splitString "/" addr);
    toAttrSet = f: v:
      builtins.listToAttrs (flatMapAttrsToList f v);

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
        name = "01-${name}";
        value = {
          netdevConfig = {
            Name = name;
            Kind = "vlan";
          };
          vlanConfig = {
            Id = tag;
          };
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
        name = "30-${name}";
        value = {
          netdevConfig = {
            Name = name;
            Kind = "wireguard";
          };
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
        ...
      }: (if batman == null then [] else [{
        name = "00-${name}";
        value = {
          netdevConfig = {
            Name = name;
            Kind = "batadv";
          };
          batmanAdvancedConfig = {
            GatewayMode = batman.gatewayMode;
            RoutingAlgorithm = batman.routingAlgorithm;
          };
        };
      }]) ++ (
        lib.attrsets.mapAttrsToList fromVlan vlans
      ) ++ (
        if wireguard == null then [] else [(fromWireguard name wireguard)]
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
          ...
      }:
        let
          ignoreCarrier = if !ignore-carrier then {} else {
            ConfigureWithoutCarrier = true;
            LinkLocalAddressing = "no"; # https://github.com/systemd/systemd/issues/9252#issuecomment-501850588
            IPv6AcceptRA=false; # https://bbs.archlinux.org/viewtopic.php?pid=1958133#p1958133
          };
          defRoute = if route != "primary" then {} else {
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

      mkLinkConfig = { mtu, required, activation-status ? null }:
        (
          if mtu == null then {} else { MTUBytes = mtu; }
        ) // (
          if required then {} else { RequiredForOnline = "no"; }
        ) // (
          if activation-status == null then {} else { ActivationPolicy = activation-status; }
        );
      mkRouteConfig = { gateway, destination, ... }:
        {
          routeConfig = {
            Gateway = gateway;
            Destination = destination;
          };
        };

      fromPppoe = name: {
        network,
          routes ? [],
          ...
      }: let
        nw-conf = mkNetworkConfig network;
      in (if nw-conf == null then {} else {
        name = "22-${name}";
        value = {
          matchConfig = { Name = name; };
          networkConfig = nw-conf // {
            KeepConfiguration = "static";
            LinkLocalAddressing = "no";
          };
          routes = builtins.map mkRouteConfig routes;
        };
      });

      fromVlan = name: {
        network,
          mtu ? null,
          pppoe ? {},
          routes ? [],
          ...
      }:
        [{
          name = "21-${name}";
          value = {
            matchConfig = { Name = name; };
            networkConfig = mkNetworkConfig network;
            linkConfig = mkLinkConfig { inherit mtu; inherit (network) required; };
            routes = builtins.map mkRouteConfig routes;
          };
        }] ++ (lib.attrsets.mapAttrsToList fromPppoe pppoe);
    in
      name: {
        network,
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
      in (if nw-conf == null then [] else [{
        name = "${if wireguard == null then "10" else "40"}-${name}";
        value = {
          matchConfig = {
            Name = name;
          };
          vlan = lib.attrsets.mapAttrsToList (name: vlan: name) vlans;
          networkConfig = (nw-conf) // (
            if batmanDevice == null then {} else { BatmanAdvanced = batmanDevice; }
          );
          linkConfig = mkLinkConfig {
            inherit mtu;
            inherit (network) required;
            activation-status = (mkActivationStatus network);
          };
          routes = builtins.map mkRouteConfig routes;
        };
      }]) ++ (
        flatMapAttrsToList fromVlan vlans
      ) ++ (
        lib.attrsets.mapAttrsToList fromPppoe pppoe
      );

    mkLinkUnits = name: {
      device ? null,
        mtu ? null,
        ...
    }:
      if device == null then [] else [{
        name = "00-${name}";
        value = {
          matchConfig = {
            MACAddress = device;
            Type = "ether";
          };
          linkConfig = {
            Name = name;
          } // (
            if mtu == null then {} else { MTUBytes = mtu; }
          );
        };
      }];

    dynamic-netdevs = toAttrSet mkNetdevUnits cfg.dynamic.topology;
    dynamic-networks = toAttrSet mkNetworkUnits cfg.dynamic.topology;
    
  in lib.mkIf cfg.enable {
    assertions = (lib.attrValues (
      lib.mapAttrs (name: value: {
        assertion = (value.wireguard != null && value.wireguard.openFirewall) -> (value.wireguard.port != null);
        message = "Cannot open the firewall for ${name} if no port is defined";
      }) cfg.topology
    ));

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
    services.resolved.enable = false;
    networking = {
      useDHCP = false;
      firewall.enable = false; # use custom nftables integration
      nameservers = builtins.filter (v: v != null) [ cfg.dns.upstream ];
    };

    systemd.network = {
      links = toAttrSet mkLinkUnits cfg.topology;
      netdevs = toAttrSet mkNetdevUnits cfg.topology;
      networks = toAttrSet mkNetworkUnits cfg.topology;
    };

    # todo: turn on when ready to do dynamic networking
    systemd.services."router-network-dynamic" = lib.mkIf (
      cfg.dynamic.topology != {}
    ) (let
      volatilePath = "/run/systemd/network";
    in {
      wants = [ "network-pre.target" ];
      before = [ "network-pre.target" ];
      path = with pkgs; [ bash envsubst ];
      # todo: once we have access to the networkd file rendering functions,
      #       use those to generate the files instead of directly using
      #       ones the user provides
      # todo: generate several smaller units that point to the same environment file
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
    });

    systemd.services."router-wireguard-dynamic-endpoint-refresh" = let
      getWireguardConf = lib.attrsets.concatMapAttrs (name: { wireguard ? {}, vlans ? {}, pppoe ? {}, ... }:
        (
          getWireguardConf vlans
        ) // (
          getWireguardConf pppoe
        ) // (
          let peers-with-refresh =
                if wireguard ? "peers"
                then builtins.filter (p:
                  p.dynamicEndpointRefreshRestartSeconds != null
                ) wireguard.peers
                else [];
          in if peers-with-refresh != [] then { ${name} = (wireguard // { peers = peers-with-refresh; }); } else {}
        ));
      wireguard-confs = getWireguardConf cfg.topology // getWireguardConf cfg.dynamic.topology;
    in lib.mkIf (wireguard-confs != {}) {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ bash wireguard-tools ];
      script = (lib.strings.concatStringsSep "\n" (
        flatMapAttrsToList (iface: {
          peers,
            ...
        }: builtins.map (peer: ''
          re=$'${builtins.replaceStrings ["+"] ["\\+"] peer.publicKey}\t([0-9]+)'
          if [[ $(wg show "${iface}" latest-handshakes) =~ $re ]]; then
            if (( ($EPOCHSECONDS - ''${BASH_REMATCH[1]}) > ${toString peer.dynamicEndpointRefreshRestartSeconds} )); then
              wg set "${iface}" peer "${peer.publicKey}" endpoint "${from-dynamic peer.endpoint}"
            fi
          fi
        '') peers) wireguard-confs
      ));
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

    services.dnsmasq = let
      dhcp-networks = networksWhere (n: n.dhcp.enable);
    in {
      enable = dhcp-networks != {};
      settings =  {
        server = builtins.filter (v: v != null) [ cfg.dns.upstream ];
        no-resolv = true;
        local = "/local/";
        domain = "local";
        expand-hosts = true;
        listen-address = [ "::1" "127.0.0.1" ];
        interface = builtins.attrNames dhcp-networks;
        bind-dynamic = true;
        dhcp-option = let
          fmt = name: { static-addresses, dns, ... }:
            (
              builtins.map (gw: "${name},3,${addrNoPrefix gw}") static-addresses
            ) ++ (
              # todo: ipv6, and do less add-hoc stuff here
              [("${name},6," + (
                if dns == "cloudflare" then "1.1.1.1,1.0.0.1"
                else if dns == "self" then "0.0.0.0"
                else abort "invalid dns type: ${dns}"
              ))]
            );
        in flatMapAttrsToList fmt dhcp-networks;
        dhcp-range = let
          fmt = { static-addresses, ... }:
            # todo: add ipv6
            builtins.map (ipv4:
              "${addrFirstN 3 ipv4}.101,${addrFirstN 3 ipv4}.200,12h"
            ) static-addresses;
        in builtins.concatMap fmt (builtins.attrValues dhcp-networks);
      };
    };
    systemd.services."dnsmasq" = {
      requires = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };

    services.avahi = {
      enable = config.services.dnsmasq.enable;
      nssmdns = true;
      publish.enable = true;
      reflector = true;
      allowInterfaces = interfacesWithTrust [ "management" "trusted" "untrusted" ];
    };

    # TODO: make mtu setting based on the topology of the pppoe device
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
          name = name;
          value = {
            enable = true;
            config = (mkConfig dev name pppoe.userfile);
          };
        };
      fromTopology = name: { vlans ? {}, pppoe ? {}, ...}:
        (flatMapAttrsToList (fromPppoe name) pppoe) ++ (flatMapAttrsToList fromTopology vlans);
      peers = builtins.listToAttrs (flatMapAttrsToList fromTopology cfg.topology);
    in {
      inherit peers;
      enable = peers != [];
      package = (pkgs.callPackage ./backports/ppp-2.4.9 { });
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
                  ) cfg.topology
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
