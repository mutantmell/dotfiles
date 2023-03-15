{ config, pkgs, lib, ... }:

# There were two main sources of inspiration for this configuration:
#   1. https://pavluk.org/blog/2022/01/26/nixos_router.html
#   2. https://francis.begyn.be/blog/nixos-home-router
# Thank you very much!
{
  options.router = with lib; {
    enable = mkEnableOption "Home Router Service";

    # TODO: this might be better suited as something tied to the overall topology?
    #       either way, this is kinda hardcoded and is worth re-thinking when we
    #       migrate to dnsmasq for dns/dhcp
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
      src-tgt = _type: types.submodule {
        options.src = mkOption {
          type = types.nullOr _type;
          description = "The ip address to permit forwarding from";
          default = null;
        };
        options.tgt = mkOption {
          type = types.nullOr _type;
          description = "The ip address to permit forwarding to";
          default = null;
        };
      };
      firewall-extras = types.submodule {
        options.ip = mkOption {
          type = src-tgt types.str;
          default = {};
        };
        options.iface = mkOption {
          type = src-tgt types.str;
          default = {};
        };
        options.tcp = mkOption {
          type = src-tgt types.int;
          default = {};
        };
        options.udp = mkOption {
          type = src-tgt types.int;
          default = {};
        };
        options.policy = mkOption {
          type = types.enum [ "accept" "drop" ];
          description = "what to do when the rule is matched";
        };
      };
    in mkOption {
      type = types.submodule {
        options.extraInput = mkOption {
          type = types.listOf firewall-extras;
          example = [{ ip.src = "192.168.1.100"; ip.tgt = "10.0.0.1";  }];
          description = "Extra firewall forwarding rules";
          default = [];
        };
        options.extraForwards = mkOption {
          type = types.listOf firewall-extras;
          example = [{ ip.src = "192.168.1.100"; ip.tgt = "10.0.0.1";  }];
          description = "Extra firewall forwarding rules";
          default = [];
        };
      };
      description = "Extra firewall rules";
      default = {};
    };
    topology = mkOption {
      type = let
        # TODO: have multiple submodules declare their exact type expectations,
        #       and merge together
        networkConf = mkOption {
          type = types.submodule {
            options = {
              type = mkOption {
                type = types.enum [ "none" "disabled" "routed" "dhcp" "static" ];
                example = "none";
                description = ''
                  Type of network this is mean to configure.  Expects one of the following network types:
                  { type = "none"; } # Don't generate a network file
                  { type = "disabled"; } # Has a network file, but with everything disabled
                  { type = "routed"; ipv4 = "..."; ipv6 = "..."; trust = trust-status } # a network that we provide routing for
                  { type = "dhcp"; trust = trust-status; } # a network where we get a dhcp address assigned -- we don't route this
                  { type = "static"; addresses = [{ address = "..."; gateway? = "..."; dns? = "..."; }]; trust = trust-status } # static ip network
                '';         
              };
              trust = mkOption {
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
              ipv4 = mkOption {
                type = types.nullOr types.str;
                example = "192.168.1.1/24";
                description = "IPV4 addresses to associate with a routed network";
                default = null;
              };
              ipv6 = mkOption {
                type = types.nullOr types.str;
                description = "IPV6 addresses to associate with a routed network";
                default = null;
              };
              dns = mkOption {
                type = types.enum [ "self" "cloudflare" ];
                description = "DNS provider to use -- either use this router, or use cloudflare";
                default = "self";
                example = "cloudflare";
              };
              static-addresses = mkOption {
                type = types.listOf types.str;
                example = [ "192.168.1.100" ];
                default = [];
                description = "Addresses to use for a static network";
              };
              static-gateways = mkOption {
                type = types.listOf types.str;
                example = [ "192.168.1.1" ];
                default = [];
                description = "Gateways to use for a static network";
              };
              static-dns = mkOption {
                type = types.listOf types.str;
                example = [ "192.168.1.1" ];
                default = [];
                description = "DNS to use for a static network";
              };
              # TODO: we should combine this with the routes option, and move routes into network
              route = mkOption {
                type = types.nullOr (types.enum [ "primary" ]);
                example = "primary";
                description = "For a DHCP network, mark this as primary/default route";
                default = null;
              };
            };
          };
          description = "configuration of the network corresponding to this device";
        };
        routesConf = mkOption {
          type = types.listOf (types.submodule {
            options = {
              gateway = mkOption {
                type = types.str;
                description = "Address of Gateway for Static Routes";
                example = "192.168.1.100";
              };
              destination = mkOption {
                type = types.str;
                description = "Address and prefix to route to the gateway";
                example = "10.0.0.0/24";
              };
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
            options = {
              userfile = mkOption {
                type = types.path;
                description = "A path of an options file that sets the name of the user";
              };
              network = networkConf;
            };
          });
          default = {};
        };
        vlanConf = mkOption {
          description = "configuration of the vlan on this device";
          type = types.attrsOf (types.submodule {
            options = {
              tag = mkOption {
                type = types.int;
                example = 123;
                description = "Tag to use for the vlan";
              };
              pppoe = pppoeConf;
              network = networkConf;
              routes = routesConf;
            };
          });
          default = {};
        };
      in types.attrsOf (types.submodule {
        options = {
          device = mkOption {
            type = types.nullOr types.str;
            example = "00:11:22:33:44:55";
            description = "MAC address of the device, to create the name for";
            default = null;
          };
          required = mkOption {
            type = types.bool;
            example = true;
            description = "Whether or not this device is required for start-up";
          };
          network = networkConf;
          vlans = vlanConf;
          pppoe = pppoeConf;
          routes = routesConf;
          mtu = mkOption {
            type = types.nullOr types.str;
            example = "1536";
            description = "override the default mtu of the device";
            default = null;
          };          
          batmanDevice = mkOption {
            type = types.nullOr types.str;
            example = "bat0";
            description = "batman-advanced network this device should be associated with, if any";
            default = null;
          };
          batman = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                gatewayMode = mkOption {
                  type = types.nullOr types.str;
                  example = "off";
                  description = "gateway mode of the batman device";
                };
                routingAlgorithm = mkOption {
                  type = types.nullOr types.str;
                  example = "batman-v";
                  description = "routing algorithm of the batman device";
                };
              };
            });
            description = "configuration of the batman device";
            default = null;
          };
        };
      });
    };
  };
  
  config = let
    cfg = config.router;
    
    flatMapAttrsToList = f: v: lib.lists.flatten (lib.attrsets.mapAttrsToList f v);
    filterMap = f: l: builtins.filter (v: v != null) (builtins.map f l);
    attrKeys = lib.attrsets.mapAttrsToList (name: ignored: name);

    interfacesWhere = pred: let
      fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (if pred network then [name] else []) ++ (flatMapAttrsToList fromTopo vlans) ++ (flatMapAttrsToList fromTopo pppoe);
    in flatMapAttrsToList fromTopo cfg.topology;

    interfacesWithTrust = tr: interfacesWhere ({ trust ? null, ... }: trust == tr);
    interfaces = interfacesWhere (nw: nw.type != "disabled");

    interfacesOfType = ty: interfacesWhere (nw: nw.type == ty);

    pppoeNames = let
      fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (attrKeys pppoe) ++ (flatMapAttrsToList fromTopo vlans);
    in flatMapAttrsToList fromTopo cfg.topology;

    # should eventually return object like { ipv4: [...]; ipv6: [...]; }
    addrsWhere = pred: let
      trustedAddr = nw@{ type, ipv4 ? null, ipv6 ? null, ... }: if type == "routed" && (pred nw) then (builtins.filter (v: v != null) [ipv4 ipv6]) else [];
      fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (trustedAddr network) ++ (flatMapAttrsToList fromTopo vlans) ++ (flatMapAttrsToList fromTopo pppoe);
    in flatMapAttrsToList fromTopo cfg.topology;

    addrsWithTrust = trust: addrsWhere (nw: nw.trust == trust);
    routedAddrs = addrsWhere (nw: true);

    addrFirstN = n: addr: lib.strings.concatStringsSep "." (lib.lists.take n (lib.strings.splitString "." addr));
    toAttrSet = f: v:
      builtins.listToAttrs (flatMapAttrsToList f v);
    
  in lib.mkIf cfg.enable {  
    boot.kernel.sysctl = let
      wans = interfacesOfType "dhcp";
    in {
      "net.ipv4.conf.all.forwarding" = true;
      "net.ipv6.conf.all.forwarding" = true;

      # source: https://github.com/mdlayher/homelab/blob/master/nixos/routnerr-2/configuration.nix#L52
      "net.ipv6.conf.all.accept_ra" = 0;
      "net.ipv6.conf.all.autoconf" = 0;
      "net.ipv6.conf.all.use_tempaddr" = 0; 
    } // (lib.lists.foldr (wan: acc: {
      "net.ipv6.conf.${wan}.accept_ra" = 2;
      "net.ipv6.conf.${wan}.autoconf" = 1;
    } // acc) {} wans);

    environment.systemPackages = with pkgs; [
      vim
      htop
      ethtool
      tcpdump
      conntrack-tools
      batctl
      bind
    ];

    networking = {
      useDHCP = false;
      useNetworkd = true;
      firewall.enable = false; # use custom nftables integration
    };

    systemd.network = {
      links = let
        fromDevices = name: {
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
      in toAttrSet fromDevices cfg.topology;

      netdevs = let
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

        fromDevices = name: {
          vlans ? {},
            batman ? null,
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
        }]) ++ (lib.attrsets.mapAttrsToList fromVlan vlans);
      in toAttrSet fromDevices cfg.topology;

      networks = let
        mkNetworkConfig = {
          type,
            trust ? null,
            ipv4 ? null,
            ipv6 ? null,
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
          in if type == "routed" then {
            Address = builtins.filter (v: v != null) [ipv4 ipv6];
            MulticastDNS = builtins.elem trust [ "trusted" "management" "untrusted" ];
            DHCPServer = true;
            IPMasquerade = "ipv4";
          } else if type == "dhcp" then defRoute // {
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
          } else if type == "none" then {
          } else abort "invalid type: ${type}";

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
        mkDhcpServerConfig = { type, ipv4 ? null, dns ? "self", ...}: if type == "routed" then {
          ServerAddress = ipv4;
          PoolOffset = 100;
          PoolSize = 100;
          EmitDNS = true;
          DNS =
            if dns == "cloudflare" then [ "1.1.1.1" "1.0.0.1" ]
            else if dns == "self" then [ "${addrFirstN 3 ipv4}.1" ]
            else abort "invalid dns type: ${dns}";
        } else {};
        fromPppoe = name: {
          network,
            routes ? [],
            ...
        }: {
          name = "20-${name}";
          value = {
            matchConfig = { Name = name; };
            networkConfig = mkNetworkConfig network // {
              KeepConfiguration = "static";
              LinkLocalAddressing = "no";
            };
            routes = builtins.map mkRouteConfig routes;
            dhcpServerConfig = mkDhcpServerConfig network;
          };
        };
        fromVlan = name: {
          network,
            mtu ? null,
            pppoe ? {},
            required ? true,
            routes ? [],
            ...
        }:
          [{
            name = "20-${name}";
            value = {
              matchConfig = { Name = name; };
              networkConfig = mkNetworkConfig network;
              linkConfig = mkLinkConfig { inherit mtu required; };
              routes = builtins.map mkRouteConfig routes;
              dhcpServerConfig = mkDhcpServerConfig network;
            };
          }] ++ (lib.attrsets.mapAttrsToList fromPppoe pppoe);
        fromDevice = name: {
          network,
            required,
            vlans ? {},
            pppoe ? {},
            batmanDevice ? null,
            mtu ? null,
            routes ? [],
            ...
        }: let
          mkActivationStatus = { type, ignore-carrier ? false, ... }:
            if ignore-carrier then "always-up" else null;
        in [{
          name = "10-${name}";
          value = {
            matchConfig = {
              Name = name;
            };
            vlan = lib.attrsets.mapAttrsToList (name: vlan: name) vlans;
            networkConfig = (mkNetworkConfig network) // (
              if batmanDevice == null then {} else { BatmanAdvanced = batmanDevice; }
            );
            linkConfig = mkLinkConfig {
              inherit mtu required;
              activation-status = (mkActivationStatus network);
            };
            routes = builtins.map mkRouteConfig routes;
          };
        }] ++ (
          flatMapAttrsToList fromVlan vlans
        ) ++ (
          lib.attrsets.mapAttrsToList fromPppoe pppoe
        );
      in toAttrSet fromDevice cfg.topology;
    };

    networking.nameservers = builtins.filter (v: v != null) [ cfg.dns.upstream ];
    services.resolved = {
      enable = true;
      extraConfig = let
        format = addr: "DNSStubListenerExtra=" + (addrFirstN 3 addr) + ".1";
        dnsExtras = builtins.map format routedAddrs;
      in ''
        ${lib.strings.concatStringsSep "\n" dnsExtras}
      '';
    };

    # TODO: make mtu setting based on the topology of the pppoe device
    services.pppd = let
      mkConfig = parentDev: pppName: userfile: ''
        plugin rp-pppoe.so ${parentDev}

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
    };

    networking.nftables = let
      external = interfacesWithTrust "external";
      management = interfacesWithTrust "management";
      trusted = (interfacesWithTrust "trusted") ++ management;
      untrusted = (interfacesWithTrust "untrusted");
      local-access = interfacesWithTrust "local-access";
      lockdown = interfacesWithTrust "lockdown";
      all-wan-access = trusted ++ untrusted;
      all-internal = all-wan-access ++ lockdown;
      quoted = dev: "\"" + dev + "\"";
      quoted-non-null = dev: if dev == null then null else quoted dev;
      rule-format = devices: (lib.strings.concatStringsSep ", " (builtins.map quoted devices)) + ",";

      fmt-src-tgt = src-fmt: tgt-fmt: { src ? null, tgt ? null }: (
        (
          if src == null then [] else [ "${src-fmt} ${src}" ]
        ) ++ (
          if tgt == null then [] else [ "${tgt-fmt} ${tgt}" ]
        )
      );
      fmt-ip = fmt-src-tgt "ip saddr" "ip daddr";
      fmt-iface = { src ? null, tgt ? null }:
        fmt-src-tgt "iifname" "oifname" { src = quoted-non-null src; tgt = quoted-non-null tgt; };
      fmt-tcp = fmt-src-tgt "tcp sport" "tcp dport";
      fmt-udp = fmt-src-tgt "udp sport" "udp dport";
      fmt-extra = { iface ? {}, ip ? {}, tcp ? {}, udp ? {}, policy }:
        lib.strings.concatStringsSep " " (
          (fmt-iface iface) ++ (fmt-ip ip) ++ (fmt-tcp tcp) ++ (fmt-udp udp) ++ [policy]
        );

      extra-forwards = lib.strings.concatStringsSep "\n" (builtins.map fmt-extra cfg.firewall.extraForwards);
      extra-input = lib.strings.concatStringsSep "\n" (builtins.map fmt-extra cfg.firewall.extraInput);
    in {
      enable = true;
      ruleset = ''
        table inet filter {
          chain output {
            type filter hook output priority 100; policy accept;
          }

          chain input {
            type filter hook input priority filter; policy drop;

            # Allow trusted networks to access the router
            iifname {
              ${rule-format (trusted ++ local-access ++ ["lo"])}
            } counter accept

            # allow untrusted access to DNS and DHCP
            iifname {
              ${rule-format untrusted}
            } tcp dport { 53 } counter accept
            iifname {
              ${rule-format untrusted}
            } udp dport { 53, 67, mdns } counter accept

            # Allow returning traffic from external and drop everthing else
            iifname {
              ${rule-format external}
            } ct state { established, related } counter accept

            ${extra-input}

            iifname {
              ${rule-format external}
            } drop
          }

          chain forward {
            type filter hook forward priority filter; policy drop;
            tcp flags syn tcp option maxseg size set rt mtu

            # Allow internal networks WAN access
            iifname {
              ${rule-format all-wan-access}
            } oifname {
              ${rule-format external}
            } counter accept comment "Allow trusted internal to WAN"

            # Allow trusted internal to all internal
            iifname {
              ${rule-format trusted}
            } oifname {
              ${rule-format all-internal}
            } counter accept comment "Allow trusted internal to all internal"

            # Allow untrusted and management access to internal https on untrusted and management
            iifname {
              ${rule-format (untrusted ++ management)}
            } oifname {
              ${rule-format (untrusted ++ management)}
            } tcp dport { https } counter accept comment "Allow untrusted access to internal management https"

            ${extra-forwards}

            # Allow established connections to return
            ct state { established, related } counter accept comment "Allow established to all internal"
          }
        }

        table ip nat {
          chain prerouting {
            type nat hook output priority filter; policy accept;
          }

          # Setup NAT masquerading on the wan interface
          chain postrouting {
            type nat hook postrouting priority filter; policy accept;
            oifname {
              ${rule-format external}
            } masquerade
          }
        }
      '';
    };
  };
}
