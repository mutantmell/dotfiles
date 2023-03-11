{ config, pkgs, lib, ... }:

let
  # There were two main sources of inspiration for this configuration:
  #   1. https://pavluk.org/blog/2022/01/26/nixos_router.html
  #   2. https://francis.begyn.be/blog/nixos-home-router
  # Thank you very much!
  #
  # network types:
  #       { type = "none"; } # Don't generate a network file
  #       { type = "disabled"; } # Has a network file, but with everything disabled
  #       { type = "routed"; ipv4 = "..."; ipv6 = "..."; trust = trust-status } # a network that we provide routing for
  #       { type = "dhcp"; trust = trust-status; } # a network where we get a dhcp address assigned -- we don't route this
  #       { type = "static"; addresses = [{ address = "..."; gateway? = "..."; dns? = "..."; }]; trust = trust-status } # static ip network
  #       trust-status = management | external | trusted | untrusted | lockdown | local-access | dmz
  # TODO: move the topology to its own file, and move the relevant extractors to there
  topology = {
    wan = {
      device = "00:e0:67:1b:70:34";
      network = { type = "disabled"; };
      required = true;
      vlans = {
        "wanCENTURYLINK" = {
          tag = 201;
          network = { type = "disabled"; };
          pppoe = {
            "pppcenturylink" = {
              # an options file that just sets the user
              # example: |
              #  user "my-pppoe-user"
              userfile = config.sops.secrets."pppd-userfile".path;
              network = { type = "dhcp"; route = "primary"; trust = "external"; };
            };
          };
        };
      };
    };
    lan = {
      device = "00:e0:67:1b:70:35";
      network = { type = "disabled"; };
      required = true;
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
          network = { type = "routed"; ipv4 = "10.0.100.1/24"; trust = "dmz"; useNetworkd = true; };
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
      network = { type = "disabled"; };
      required = false;
    };
    bat0 = {
      batman = {
        gatewayMode = "off";
        routingAlgorithm = "batman-v";
      };
      network = { type = "disabled"; };
      required = true;
      vlans = {
        "vMGMT.bat0" = {
          tag = 1010;
          network = { type = "routed"; ipv4 = "10.1.10.1/24"; trust = "management"; };
        };
        "vHOME.bat0" = {
          tag = 1020;
          network = { type = "routed"; ipv4 = "10.1.20.1/24"; trust = "trusted"; };
        };
        "vGUEST.bat0" = {
          tag = 1030;
          network = { type = "routed"; ipv4 = "10.1.30.1/24"; trust = "untrusted"; };
        };
        "vIOT.bat0" = {
          tag = 1040;
          network = { type = "routed"; ipv4 = "10.1.40.1/24"; trust = "untrusted"; };
        };
        "vGAME.bat0" = {
          tag = 1041;
          network = { type = "routed"; ipv4 = "10.1.41.1/24"; trust = "untrusted"; };
        };
      };
    };
    opt2 = {
      device = "00:e0:67:1b:70:37";
      network = { type = "disabled"; };
      #network = { type = "static"; ignore-carrier = true; addresses = [{address="192.168.1.1/32"; gateway="192.168.1.1"; dns="192.168.1.1";}]; trust = "local-access"; };
      required = false;
    };
  };

  flatMapAttrsToList = f: v: lib.lists.flatten (lib.attrsets.mapAttrsToList f v);
  filterMap = f: l: builtins.filter (v: v != null) (builtins.map f l);
  attrKeys = lib.attrsets.mapAttrsToList (name: ignored: name);

  interfacesWhere = pred: let
    fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (if pred network then [name] else []) ++ (flatMapAttrsToList fromTopo vlans) ++ (flatMapAttrsToList fromTopo pppoe);
  in flatMapAttrsToList fromTopo topology;

  interfacesWithTrust = tr: interfacesWhere ({ trust ? null, ... }: trust == tr);
  interfaces = interfacesWhere (nw: nw.type != "disabled");

  interfacesOfType = ty: interfacesWhere (nw: nw.type == ty);

  pppoeNames = let
    fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (attrKeys pppoe) ++ (flatMapAttrsToList fromTopo vlans);
  in flatMapAttrsToList fromTopo topology;

  # should eventually return object like { ipv4: [...]; ipv6: [...]; }
  addrsWhere = pred: let
    trustedAddr = nw@{ type, ipv4 ? null, ipv6 ? null, ... }: if type == "routed" && (pred nw) then (builtins.filter (v: v != null) [ipv4 ipv6]) else [];
    fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (trustedAddr network) ++ (flatMapAttrsToList fromTopo vlans) ++ (flatMapAttrsToList fromTopo pppoe);
  in flatMapAttrsToList fromTopo topology;

  addrsWithTrust = trust: addrsWhere (nw: nw.trust == trust);
  routedAddrs = addrsWhere (nw: true);

  addrFirstN = n: addr: lib.strings.concatStringsSep "." (lib.lists.take n (lib.strings.splitString "." addr));
  toAttrSet = f: v:
    builtins.listToAttrs (flatMapAttrsToList f v);
in {
  boot.kernel.sysctl = let
    externals = interfacesWithTrust "external";
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
  } // acc) {} externals);

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
    in toAttrSet fromDevices topology;

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
    in toAttrSet fromDevices topology;

    networks = let
      mkNetworkConfig = {
        type,
          trust ? null,
          ipv4 ? null,
          ipv6 ? null,
          ignore-carrier ? false,
          route ? null,
          addresses ? [],
          useNetworkd ? false,
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
          MulticastDNS = builtins.elem trust [ "trusted" "management" "untrusted" "dmz" ];
          DHCPServer = useNetworkd;
          IPMasquerade = if useNetworkd then "ipv4" else "no";
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
          Address = filterMap ({address ? null, ...}: address) addresses;
          Gateway = filterMap ({gateway ? null, ...}: gateway) addresses;
          DNS = filterMap ({dns ? null, ...}: dns) addresses;
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
      #  { type = "routed"; ipv4 = "10.0.100.1/24"; trust = "dmz"; useNetworkd = true; };
      mkDhcpServerConfig = { type, ipv4 ? null, useNetworkd ? false, dns ? "self", ...}: if type == "routed" && useNetworkd then {
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
    in toAttrSet fromDevice topology;
  };

  networking.nameservers = [ "10.0.10.2" ];
  services.resolved = {
    enable = true;
    extraConfig = let
      format = addr: "DNSStubListenerExtra=" + (addrFirstN 3 addr) + ".1";
      dnsExtras = builtins.map format routedAddrs;
    in ''
      ${lib.strings.concatStringsSep "\n" dnsExtras}
    '';
  };

  services.dhcpd4 = let
    toAddress24 = addrFirstN 3;
    v4Interfaces = let
      mkConf = name: { type, ipv4 ? null, dns ? "self", useNetworkd ? false, ...}: if (type == "routed" && !useNetworkd && ipv4 != null) then [{ address24 = toAddress24 ipv4; iface = name; dns = dns; }] else [];
      fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (mkConf name network) ++ (flatMapAttrsToList fromTopo vlans) ++ (flatMapAttrsToList fromTopo pppoe);
    in flatMapAttrsToList fromTopo topology;
  in {
    enable = v4Interfaces != [];
    interfaces = builtins.map ({ iface, ... }: iface) v4Interfaces;
#    extraFlags = [ "-d2" ];
    extraConfig = let
      preamble = ''
        option domain-name "local";
        option subnet-mask 255.255.255.0;
      '';
      mkV4Subnet = { address24, iface, dns }: let
        domainNameServers =
          if dns == "cloudflare" then "1.1.1.1, 1.0.0.1"
          else if dns == "self" then "${address24}.1"
          else abort "invalid dns type: ${dns}";
      in ''
        subnet ${address24}.0 netmask 255.255.255.0 {
          option broadcast-address ${address24}.255;
          option routers ${address24}.1;
          option domain-name-servers ${domainNameServers};
          interface "${iface}";
          range ${address24}.100 ${address24}.200;
        }
      '';
      subnetConfs = builtins.map mkV4Subnet v4Interfaces;

    in lib.strings.concatStringsSep "\n\n" ([preamble] ++ subnetConfs);
  };

  # services.dhcpd6 = let
  #   toAddress48 = addr: "";
  #   v6Interfaces = let
  #     mkConf = name: { type, ipv6 ? null, dns ? "self", ...}: if (type == "routed" && ipv6 != null) then [{ address48 = toAddress48 ipv6; iface = name; dns = dns; }] else [];
  #     fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (mkConf name network) ++ (flatMapAttrsToList fromTopo vlans) ++ (flatMapAttrsToList fromTopo pppoe);
  #   in flatMapAttrsToList fromTopo topology;
  # in {
  #   enable = false;
  # };

  # TODO: make mtu setting based on the config
  services.pppd = {
    enable = true;
    peers = let
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
    in builtins.listToAttrs (flatMapAttrsToList fromTopology topology);
  };

  networking.nftables = let
    external = interfacesWithTrust "external";
    management = interfacesWithTrust "management";
    trusted = (interfacesWithTrust "trusted") ++ management;
    untrusted = (interfacesWithTrust "untrusted") ++ (interfacesWithTrust "dmz");
    local-access = interfacesWithTrust "local-access";
    lockdown = interfacesWithTrust "lockdown";
    all-wan-access = trusted ++ untrusted;
    all-internal = all-wan-access ++ lockdown;
    quoted = dev: "\"" + dev + "\"";
    ruleFormat = devices: (lib.strings.concatStringsSep ", " (builtins.map quoted devices)) + ",";
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
            ${ruleFormat (trusted ++ local-access ++ ["lo"])}
          } counter accept

          # allow untrusted access to DNS and DHCP
          iifname {
            ${ruleFormat untrusted}
          } tcp dport { 53 } counter accept
          iifname {
            ${ruleFormat untrusted}
          } udp dport { 53, 67, mdns } counter accept

          # Allow returning traffic from external and drop everthing else
          iifname {
            ${ruleFormat external}
          } ct state { established, related } counter accept
          iifname {
            ${ruleFormat external}
          } drop
        }

        chain forward {
          type filter hook forward priority filter; policy drop;
          tcp flags syn tcp option maxseg size set rt mtu

          # Allow internal networks WAN access
          iifname {
            ${ruleFormat all-wan-access}
          } oifname {
            ${ruleFormat external}
          } counter accept comment "Allow trusted internal to WAN"

          # Allow trusted internal to all internal
          iifname {
            ${ruleFormat trusted}
          } oifname {
            ${ruleFormat all-internal}
          } counter accept comment "Allow trusted internal to all internal"

          # Allow untrusted and management access to internal https on untrusted and management
          iifname {
            ${ruleFormat (untrusted ++ management)}
          } oifname {
            ${ruleFormat (untrusted ++ management)}
          } tcp dport { https } counter accept comment "Allow untrusted access to internal management https"

          # Allow established connections to return
          ct state established,related counter accept comment "Allow established to all internal"
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
            ${ruleFormat external}
          } masquerade
        }
      }
    '';
  };

  systemd.services = {
    dhcpd4.after = [ "network-online.target" ];
  };
}
