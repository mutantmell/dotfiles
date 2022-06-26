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
  #       { type = "static"; ipv4 = "..."; ipv6 = "..."; otherNetworkConfig = "..."; trust = trust-status } # static ip network
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
              user = "***REMOVED***";
              network = { type = "dhcp"; trust = "external"; };
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
          network = { type = "routed"; ipv4 = "10.0.100.1/24"; trust = "dmz"; };
        };
      };
    };
    opt1 = {
      device = "00:e0:67:1b:70:36";
      network = { type = "disabled"; };
      required = true;
      mtu = "1536";
      batmanDevice = "bat0";
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
          mtu = "1536";
        };
        "vHOME.bat0" = {
          tag = 1020;
          network = { type = "routed"; ipv4 = "10.1.20.1/24"; trust = "trusted"; };
          mtu = "1536";
        };
        "vGUEST.bat0" = {
          tag = 1030;
          network = { type = "routed"; ipv4 = "10.1.30.1/24"; trust = "untrusted"; };
          mtu = "1536";
        };
        "vIOT.bat0" = {
          tag = 1040;
          network = { type = "routed"; ipv4 = "10.1.40.1/24"; trust = "untrusted"; };
          mtu = "1536";
        };
        "vGAME.bat0" = {
          tag = 1041;
          network = { type = "routed"; ipv4 = "10.1.41.1/24"; trust = "untrusted"; };
          mtu = "1536";
        };
      };
    };
    opt2 = {
      device = "00:e0:67:1b:70:37";
      network = { type = "dhcp"; trust = "local-access"; };
      required = false;
    };
  };

  flatMapAttrsToList = f: v: lib.lists.flatten (lib.attrsets.mapAttrsToList f v);
  attrKeys = lib.attrsets.mapAttrsToList (name: ignored: name);

  interfacesWhere = pred: let
    fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (if pred network then [name] else []) ++ (flatMapAttrsToList fromTopo vlans) ++ (flatMapAttrsToList fromTopo pppoe);
  in flatMapAttrsToList fromTopo topology;

  interfacesWithTrust = tr: interfacesWhere ({ trust ? null, ... }: trust == tr);
  interfaces = interfacesWhere (nw: nw.type != "disabled");

  interfacesOfType = ty: interfacesWhere (nw: nw.type == ty);
  routedInterfaces = interfacesOfType "routed";

  pppoeNames = let
    fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (attrKeys pppoe) ++ (flatMapAttrsToList fromTopo vlans);
  in flatMapAttrsToList fromTopo topology;

  # should eventually return ipv4 + ipv6
  addrsWhere = pred: let
    trustedAddr = nw: if nw.type == "routed" && (pred nw) then [nw.ipv4] else [];
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
    #    nat.enable = false;
    firewall.enable = false;
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
          ...
      }:
        if type == "routed" then {
          Address = ipv4; # eventually: Addressess = [ipv4] ++ [ipv6]
          MulticastDNS = (trust == "trusted" || trust == "management");
        } else if type == "dhcp" then {
          DHCP = "ipv4";
        } else if type == "disabled" then {
          DHCP = "no";
          DHCPServer = false;
          LinkLocalAddressing = "no";
          LLMNR = false;
          MulticastDNS = false;
          LLDP = false;
          EmitLLDP = false;
          IPv6AcceptRA = false;
          IPv6SendRA = false;
        } else {}; # "none"

      mkLinkConfig = mtu: required:
        (
          if mtu == null then {} else { MTUBytes = mtu; }
        ) // (
          if required then {} else { RequiredForOnline = false; }
        );
      fromVlan = name: {
        network,
          mtu ? null,
          required ? true,
          ...
      }:
        {
          name = "20-${name}";
          value = {
            matchConfig = { Name = name; };
            networkConfig = mkNetworkConfig network;
            linkConfig = mkLinkConfig mtu required;
          };
        };
      fromDevice = name: {
        network,
          required,
          vlans ? {},
          batmanDevice ? null,
          mtu ? null,
          ...
      }: [{
        name = "10-${name}";
        value = {
          matchConfig = {
            Name = name;
          };
          vlan = lib.attrsets.mapAttrsToList (name: vlan: name) vlans;
          networkConfig = (mkNetworkConfig network) // (
            if batmanDevice == null then {} else { BatmanAdvanced = batmanDevice; }
          );
          linkConfig = mkLinkConfig mtu required;
        };
      }] ++ (lib.attrsets.mapAttrsToList fromVlan vlans);
    in toAttrSet fromDevice topology;
  };

  services.avahi = {
    #enable = true;
    interfaces = (interfacesWithTrust "management") ++ (interfacesWithTrust "trusted");
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      userServices = true;
    };
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

  services.dhcpd4 = {
    enable = true;
    interfaces = routedInterfaces;
    extraConfig = let
      preamble = ''
        option domain-name "local";
        option subnet-mask 255.255.255.0;
      '';
      toAddress24 = addrFirstN 3;
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
      subnetConfs = let
        mkConf = name: { type, ipv4 ? "", dns ? "self", ...}: if type == "routed" then [(mkV4Subnet { address24 = toAddress24 ipv4; iface = name; dns = dns; })] else [];
        fromTopo = name: { network, vlans ? {}, pppoe ? {}, ... }: (mkConf name network) ++ (flatMapAttrsToList fromTopo vlans) ++ (flatMapAttrsToList fromTopo pppoe);
      in flatMapAttrsToList fromTopo topology;
    in lib.strings.concatStringsSep "\n\n" ([preamble] ++ subnetConfs);
  };

  services.pppd = {
    enable = true;
    peers = let
      mkConfig = parentDev: pppName: user: ''
        plugin rp-pppoe.so ${parentDev}

        hide-password
        user "${user}"

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
            config = (mkConfig dev name pppoe.user);
          };
        };
      fromTopology = name: { vlans ? {}, pppoe ? {}, ...}:
        (flatMapAttrsToList (fromPppoe name) pppoe) ++ (flatMapAttrsToList fromTopology vlans);
    in builtins.listToAttrs (flatMapAttrsToList fromTopology topology);
  };

  networking.nftables = let
    external = interfacesWithTrust "external";
    trusted = (interfacesWithTrust "trusted") ++ (interfacesWithTrust "management");
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
          } udp dport { 53, 67 } counter accept

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
    #nftables.after = builtins.map (pppoeName: "pppd-${pppoeName}.service") pppoeNames;
    dhcpd4.after = [ "network-online.target" ];
  };
  #// (
  #  builtins.listToAttrs (builtins.map (pppoeName: { name = "pppd-${pppoeName}"; value = { wants = [ "network-online.target" ]; }; }) pppoeNames)
  #)
}
