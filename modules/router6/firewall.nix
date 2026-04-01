{
  config,
  lib,
  ...
}: let
  cfg = config.router6;
  nft = import ../../lib/nftables.nix {inherit lib;};
  r6lib = import ./lib.nix {inherit cfg lib;};

  inherit
    (lib)
    optionals
    mapAttrsToList
    filterAttrs
    optionalAttrs
    concatStringsSep
    filter
    ;
  inherit (builtins) attrNames hasAttr length head elemAt;
  inherit
    (r6lib)
    flattenTopology
    interfacesWhere
    interfacesInZone
    zonesInterfaces
    activeZones
    natInterfaces
    parseIPAddress
    partitionAF
    firstIPv4
    firstIPv6
    getEffectiveAddresses
    zoneAllowsDns
    concatSections
    renderSection
    ;
in {
  config = lib.mkIf cfg.enable {
    networking.nftables = {
      enable = true;
      ruleset = let
        # Wireguard ports that need to be opened
        wgPorts = filter (p: p != null) (mapAttrsToList (
            name: iface:
              if iface.wireguard != null && iface.wireguard.openFirewall && iface.wireguard.port != null
              then iface.wireguard.port
              else null
          )
          cfg.topology);

        # Port forwarding helper — builds protocol + interface match
        mkProtoMatch = {
          proto,
          iifname,
          dport,
        }:
          if proto == "both"
          then {
            inherit iifname;
            meta.l4proto = "{ tcp, udp }";
            th.dport = dport;
          }
          else {
            inherit iifname;
            ${proto}.dport = dport;
          };

        # DNAT prerouting rules
        dnatRulesList =
          map (
            pf:
              (mkProtoMatch {
                inherit (pf) proto;
                iifname = pf.sourceInterface;
                dport = pf.sourcePort;
              })
              // {verdict = {dnat = pf.destination;};}
          )
          cfg.firewall.portForwards;

        # Port forward accept rules for forward chain
        forwardDnatRulesList =
          map (
            pf: let
              destParts = lib.splitString ":" pf.destination;
              destIP = head destParts;
              destPort = elemAt destParts 1;
            in
              (mkProtoMatch {
                inherit (pf) proto;
                iifname = pf.sourceInterface;
                dport = destPort;
              })
              // {
                ip.daddr = destIP;
                verdict = "accept";
              }
              // optionalAttrs (pf.destinationInterface != null) {oifname = pf.destinationInterface;}
          )
          cfg.firewall.portForwards;

        # DNS interception DNAT rules
        # Redirects non-router DNS traffic to the router's kresd instance.
        # Excludes: configured upstream/exclude addresses (source), all router IPs (destination).
        dnsIntercept = cfg.dns.interception;

        # Plain IP addresses (not CIDR) — use parseIPAddress so partitionAF works
        dnsExcludes = partitionAF (map parseIPAddress (
          (
            if dnsIntercept.excludeAddresses != []
            then dnsIntercept.excludeAddresses
            else cfg.dns.upstream
          )
          ++ dnsIntercept.extraExcludeAddresses
        ));

        allRouterAddrs = lib.concatMap getEffectiveAddresses flattenTopology;
        routerIPs = partitionAF allRouterAddrs;

        dnsTargets = let
          dnsIfaceAddrs =
            lib.concatMap getEffectiveAddresses
            (filter (i: let
              z = i.network.zone or null;
            in
              z != null && hasAttr z cfg.zones && zoneAllowsDns z)
            flattenTopology);
        in {
          v4 =
            if dnsIntercept.target != null
            then parseIPAddress dnsIntercept.target
            else firstIPv4 dnsIfaceAddrs;
          v6 =
            if dnsIntercept.target6 != null
            then parseIPAddress dnsIntercept.target6
            else firstIPv6 dnsIfaceAddrs;
        };

        mkNftSet = addrs:
          if length addrs == 1
          then head addrs
          else "{ ${concatStringsSep ", " addrs} }";

        # Build interception rules for one address family.
        # All inputs are parsed address objects; .ip is extracted here at the nftables boundary.
        mkDnsInterceptRules = {
          af,
          excludes,
          routers,
          target,
        }:
          optionals (dnsIntercept.enable && target != null) (
            let
              srcExcludes = lib.unique (map (a: a.ip) excludes);
              dstExcludes = lib.unique (map (a: a.ip) (routers ++ excludes));
              afAttrs =
                optionalAttrs (srcExcludes != []) {saddr = {not = mkNftSet srcExcludes;};}
                // optionalAttrs (dstExcludes != []) {daddr = {not = mkNftSet dstExcludes;};};
              dnatTarget =
                if af == "ip6"
                then "[${target.ip}]:53"
                else "${target.ip}:53";
              mkRule = proto: {
                ${af} = afAttrs;
                ${proto}.dport = 53;
                verdict = {dnat = dnatTarget;};
              };
            in [(mkRule "udp") (mkRule "tcp")]
          );

        dnsInterceptV4RulesList = mkDnsInterceptRules {
          af = "ip";
          excludes = dnsExcludes.v4;
          routers = routerIPs.v4;
          target = dnsTargets.v4;
        };

        dnsInterceptV6RulesList = mkDnsInterceptRules {
          af = "ip6";
          excludes = dnsExcludes.v6;
          routers = routerIPs.v6;
          target = dnsTargets.v6;
        };

        # Indentation helper
        ind = "              ";

        # Base rules for input chain
        inputBaseRules = optionals cfg.firewall.baseRules [
          "# Accept established/related, drop invalid"
          {
            ct.state = ["established" "related"];
            verdict = "accept";
          }
          {
            ct.state = "invalid";
            verdict = "drop";
          }
          ""
          "# Accept loopback"
          {
            iifname = "lo";
            verdict = "accept";
          }
          ""
          "# Accept essential ICMP/ICMPv6 from anywhere (required for network operation)"
          "# - destination-unreachable: connection handling"
          "# - packet-too-big (v6) / frag-needed (v4): Path MTU Discovery (critical)"
          "# - time-exceeded: traceroute, TTL expiry"
          "# - parameter-problem: malformed packet notification"
          {
            icmp.type = ["destination-unreachable" "time-exceeded" "parameter-problem"];
            verdict = "accept";
          }
          {
            icmpv6.type = ["destination-unreachable" "packet-too-big" "time-exceeded" "parameter-problem"];
            verdict = "accept";
          }
          ""
          "# Accept Neighbor Discovery (required for IPv6 to function - like ARP for IPv4)"
          {
            icmpv6.type = ["nd-router-solicit" "nd-router-advert" "nd-neighbor-solicit" "nd-neighbor-advert"];
            verdict = "accept";
          }
        ];

        # Generate zone input rules (ICMP echo + inputRules)
        # DHCPv6 client rule: allow incoming DHCPv6 responses (UDP port 546)
        # DHCPv6 uses regular UDP sockets (unlike DHCPv4 which uses raw sockets),
        # so it IS subject to nftables. Solicits go to multicast ff02::1:2,
        # making conntrack unable to match the unicast response as "established".
        dhcp6ClientIfaces =
          interfacesWhere (i:
            i.network.type == "dhcp" || (i.network.ipv6PrefixDelegation.enable or false));

        zoneInputRules =
          lib.concatMap (
            zoneName: let
              zone = cfg.zones.${zoneName};
              ifaces = interfacesInZone zoneName;
              limitOrNull =
                if cfg.firewall.icmpRateLimit != null
                then cfg.firewall.icmpRateLimit
                else null;
              icmpV4Rules = optionals (zone.icmpEcho == "enable" || zone.icmpEcho == "ipv4-only") [
                {
                  iifname = ifaces;
                  icmp.type = ["echo-request" "echo-reply"];
                  limit = limitOrNull;
                  verdict = "accept";
                }
              ];
              icmpV6Rules = optionals (zone.icmpEcho == "enable" || zone.icmpEcho == "ipv6-only") [
                {
                  iifname = ifaces;
                  icmpv6.type = ["echo-request" "echo-reply"];
                  limit = limitOrNull;
                  verdict = "accept";
                }
              ];
              inputLines = map (rule: rule // {iifname = ifaces;}) zone.inputRules;
            in
              if ifaces == []
              then []
              else icmpV4Rules ++ icmpV6Rules ++ inputLines
          )
          activeZones;

        # DHCPv6 client responses (bypasses conntrack — multicast Solicit)
        dhcp6ClientRules = optionals (dhcp6ClientIfaces != []) [
          {
            iifname = dhcp6ClientIfaces;
            udp.dport = 546;
            verdict = "accept";
          }
        ];

        # Wireguard port rules
        wgRules = optionals (wgPorts != []) [
          {
            udp.dport = wgPorts;
            verdict = "accept";
          }
        ];

        # Base rules for forward chain
        forwardBaseRules = optionals cfg.firewall.baseRules [
          "# Accept established/related, drop invalid"
          {
            ct.state = ["established" "related"];
            verdict = "accept";
          }
          {
            ct.state = "invalid";
            verdict = "drop";
          }
          ""
          "# Clamp MSS to path MTU"
          "tcp flags syn tcp option maxseg size set rt mtu"
        ];

        # Generate zone forward rules (accessTo)
        zoneForwardAccessRules =
          lib.concatMap (
            zoneName: let
              zone = cfg.zones.${zoneName};
              srcIfaces = interfacesInZone zoneName;
              dstIfaces = zonesInterfaces zone.accessTo;
            in
              if srcIfaces != [] && dstIfaces != []
              then [
                {
                  iifname = srcIfaces;
                  oifname = dstIfaces;
                  verdict = "accept";
                }
              ]
              else []
          )
          activeZones;

        # Generate zone forward filter rules (forwardRules)
        zoneForwardFilterRules =
          lib.concatMap (
            zoneName: let
              zone = cfg.zones.${zoneName};
              srcIfaces = interfacesInZone zoneName;
            in
              lib.concatLists (lib.mapAttrsToList (
                  dstZone: rulesList: let
                    dstIfaces = interfacesInZone dstZone;
                  in
                    if srcIfaces != [] && dstIfaces != [] && rulesList != []
                    then
                      map (rule:
                        rule
                        // {
                          iifname = srcIfaces;
                          oifname = dstIfaces;
                        })
                      rulesList
                    else []
                )
                zone.forwardRules)
          )
          activeZones;

        # Port forward accept rules for forward chain
        forwardDnatAcceptRules = forwardDnatRulesList;

        # Drop logging (rate-limited log + explicit drop before implicit policy drop)
        mkDropLog = chain:
          optionals cfg.firewall.logDropped [
            {
              limit = cfg.firewall.logDroppedRateLimit;
              log = "DROP-${chain}: ";
              counter = true;
              verdict = "drop";
            }
            {
              counter = true;
              verdict = "drop";
            }
          ];

        # Egress (output) chain rules
        egressPolicy =
          if cfg.firewall.egressPolicy == "drop"
          then "drop"
          else "accept";
        egressChainRules =
          if cfg.firewall.egressPolicy == "accept"
          then ""
          else let
            # Base egress rules
            egressBaseRules = [
              {
                ct.state = ["established" "related"];
                verdict = "accept";
              }
              {
                oifname = "lo";
                verdict = "accept";
              }
              {
                icmp.type = ["destination-unreachable" "time-exceeded" "parameter-problem" "echo-request" "echo-reply"];
                verdict = "accept";
              }
              {
                icmpv6.type = ["destination-unreachable" "packet-too-big" "time-exceeded" "parameter-problem" "echo-request" "echo-reply" "nd-router-solicit" "nd-router-advert" "nd-neighbor-solicit" "nd-neighbor-advert"];
                verdict = "accept";
              }
            ];
            # User-defined egress rules
            egressUserRules = cfg.firewall.egressRules;
            # Log unmatched egress traffic
            egressLog = optionals (cfg.firewall.egressPolicy == "log") [
              {
                limit = cfg.firewall.logDroppedRateLimit;
                log = cfg.firewall.egressLogPrefix;
                counter = true;
              }
            ];
            allEgressRules = concatSections [egressBaseRules egressUserRules egressLog];
          in "${ind}${nft.rulesToStringIndented ind allEgressRules}";

        # Combine all input chain rules
        allInputRules = concatSections [
          inputBaseRules
          zoneInputRules
          dhcp6ClientRules
          wgRules
          cfg.firewall.extraInputRules
          (mkDropLog "INPUT")
        ];

        # Combine all forward chain rules
        allForwardRules = concatSections [
          forwardBaseRules
          zoneForwardAccessRules
          zoneForwardFilterRules
          forwardDnatAcceptRules
          cfg.firewall.extraForwardRules
          (mkDropLog "FORWARD")
        ];

        # NAT prerouting rules (DNAT / port forwarding + DNS interception)
        natPreroutingRules = concatSections [
          dnatRulesList
          dnsInterceptV4RulesList
          cfg.firewall.extraNatRules
        ];

        # NAT postrouting rules (masquerade)
        masqueradeRules = optionals (natInterfaces != []) [
          {
            oifname = natInterfaces;
            masquerade = true;
          }
        ];
        natPostroutingRules = concatSections [
          masqueradeRules
          cfg.firewall.extraNatPostroutingRules
        ];

        # IPv6 NAT prerouting rules
        nat6PreroutingRules = concatSections [
          dnsInterceptV6RulesList
          cfg.firewall.extraNat6Rules
        ];

        # IPv6 NAT postrouting rules
        nat6PostroutingRules = cfg.firewall.extraNat6PostroutingRules;
      in ''
                  table inet filter {
                    chain input {
                      type filter hook input priority filter; policy drop;
        ${renderSection ind allInputRules}
                    }

                    chain forward {
                      type filter hook forward priority filter; policy drop;
        ${renderSection ind allForwardRules}
                    }

                    chain output {
                      type filter hook output priority filter; policy ${egressPolicy};
        ${egressChainRules}
                    }
                  }

                  table ip nat {
                    chain prerouting {
                      type nat hook prerouting priority dstnat;
        ${renderSection ind natPreroutingRules}
                    }

                    chain postrouting {
                      type nat hook postrouting priority srcnat;
        ${renderSection ind natPostroutingRules}
                    }
                  }

                  # IPv6 NAT table
                  # ULA addresses are used for internal IPv6 communication only
                  table ip6 nat {
                    chain prerouting {
                      type nat hook prerouting priority dstnat;
        ${renderSection ind nat6PreroutingRules}
                    }

                    chain postrouting {
                      type nat hook postrouting priority srcnat;
        ${renderSection ind nat6PostroutingRules}
                    }
                  }
      '';
    };
  };
}
