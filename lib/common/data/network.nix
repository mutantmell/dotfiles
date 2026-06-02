{lib}: let
  ulaPrefix = "fdc6:55f2:0a5e";

  # Per-gateway address-space split.
  # thebeyond owns: 10.91.0.0/16 + ULA group 0 (fdc6:55f2:0a5e:00xx::/64)
  # bt8gw owns:     10.97.0.0/16 + ULA group 1 (fdc6:55f2:0a5e:10xx::/64)
  gateways = {
    thebeyond = {
      prefix4 = "10.91";
      ulaGroup = 0;
    };
    bt8gw = {
      prefix4 = "10.97";
      ulaGroup = 1;
    };
  };

  # Encode gateway group + VLAN ID as a 4-hex-digit ULA subnet ID.
  # thebeyond (group 0): vlan 10 → "000a", vlan 100 → "0064"
  # bt8gw     (group 1): vlan 11 → "100b", vlan 20  → "1014"
  # Encode gateway group + VLAN ID as a 4-hex-digit ULA subnet segment.
  # group becomes the leading hex digit(s); vlanId fills the remaining 3 digits.
  # thebeyond (group 0): vlan 10 → "0" ++ "00a" = "000a"
  # bt8gw     (group 1): vlan 11 → "1" ++ "00b" = "100b"
  ulaSubnetHex = group: vlanId: let
    groupHex = lib.toLower (lib.toHexString group);
  in "${groupHex}${lib.fixedWidthString 3 "0" (lib.toLower (lib.toHexString vlanId))}";

  hostHex = hostId: lib.toLower (lib.toHexString hostId);

  # Network definitions — each network carries its VLAN ID, address-space owner, and hosts.
  # Host values are host IDs (last octet / interface identifier).
  # gateway: which entry in the `gateways` table determines this subnet's IP address space
  #   (10.91.x.x for thebeyond, 10.97.x.x for bt8gw). This is stable — it does not change
  #   when routing responsibility migrates between routers (e.g. Phase 3 cutover).
  #   May be omitted only when BOTH prefix4 and prefix6 are overridden (transit zone).
  # prefix4/prefix6: override the gateway-derived prefix (used for transit and dmz freeze).
  # prefixLength4/prefixLength6: override default /24 and /64.
  rawNetworks = {
    network = {
      vlanId = 10;
      gateway = "thebeyond";
      hosts = {
        # Transport IDs 1–9 (gateways, wireless-bridge mgmt, future switches)
        thebeyond = 1;
        bt8bridge = 4; # wireless-bridge mgmt (wired to thebeyond — 0 mesh hops)
        # IDs 2-3 reserved for future transport
        # 5-9 reserved for office-side dumb APs (1 mesh hop via BT8-bridge)
        arseille = 12; # L2 switch (deferred reclassification)
        # Service IDs 10+ (DNS, etc.)
        phantasma = 10;
      };
    };
    management = {
      vlanId = 11;
      gateway = "bt8gw";
      hosts = {
        messeldam = 6; # Keycloak OIDC (calvard)
        basel = 7; # step-ca / PKI (calvard)
        tharbad = 5; # Prometheus+Loki+Alertmanager+ntfy (calvard)
        liberl = 20; # NAS — before VM hosts
        calvard = 30; # VM host
        erebonia = 31; # VM host
        roer = 32; # deployd API (erebonia)
      };
    };
    trusted = {
      vlanId = 20;
      gateway = "bt8gw";
      hosts = {
        azoth = 50; # Raspberry Pi (Home Assistant, MQTT)
      };
    };
    lab = {
      vlanId = 21;
      gateway = "bt8gw";
      hosts = {
        edith = 42; # Dev environment / task runner (calvard Incus container)
        bose = 43; # Arr stack — UHD/4K — Sonarr, Radarr, Bazarr (liberl)
        ravennue = 44; # Arr stack — SD/1080p — Sonarr, Radarr (liberl)
      };
    };
    untrusted = {
      vlanId = 30;
      gateway = "thebeyond";
      hosts = {
        arcus = 10; # Steam Deck (guest WiFi)
      };
    };
    adu = {
      vlanId = 31;
      gateway = "thebeyond";
      hosts = {
        glorious = 20;
      };
    };
    iot = {
      vlanId = 40;
      gateway = "thebeyond";
      hosts = {};
    };
    game = {
      vlanId = 41;
      gateway = "thebeyond";
      hosts = {};
    };
    dmz = {
      vlanId = 100;
      gateway = "thebeyond";
      hosts = {
        trista = 51; # NixOS workstation / dev environment, SSH over wg-ba in DMZ (erebonia Incus VM)
        langport = 41; # Reverse proxy (calvard)
      };
    };
    # Services VLAN — terminates on BT8-gateway in Phase 2. No interface on
    # thebeyond (member-only bridge for L2 mesh passthrough). Populated as
    # services migrate from DMZ in Phase 5.
    app = {
      vlanId = 50;
      gateway = "bt8gw";
      hosts = {
        oracion = 52; # Jellyfin/Navidrome/Retrom media server (calvard) — moved from dmz in Phase 5.A
        zeiss = 31; # Attic binary cache (liberl) — moved from dmz in Phase 5.A.2
        creil = 53; # Forgejo git hosting (calvard) — moved from dmz in Phase 5.A.1
        "saint-arkh" = 61; # Forgejo Actions CI/CD runners (erebonia) — moved from dmz in Phase 5.A.3
      };
    };
    # BT8-gw-side network-gear management VLAN (parallel of network/10 on
    # thebeyond's side). Populated by a follow-up plan when wired-to-BT8-gw
    # gear (managed switches, PDUs, BMCs) lands here.
    netmgmt = {
      vlanId = 12;
      gateway = "bt8gw";
      hosts = {};
    };
    # Point-to-point /30 + /64 link between thebeyond and BT8-gateway. The
    # only zone without a gateway-table owner — its addresses sit outside
    # both per-gateway address spaces, so both prefix4 and prefix6 are
    # overridden directly. BT8-gateway is the only registered host (its
    # address is the only one referenced by router6.routes nexthops); the
    # thebeyond side is the implicit `.1` via gateway4/gateway6.
    transit = {
      vlanId = 255;
      prefix4 = "10.255.255";
      prefix6 = "${ulaPrefix}:ffff";
      prefixLength4 = 30;
      hosts = {
        bt8gw = 2;
      };
    };
  };

  # --- Validation ---
  # Catch structural errors in rawNetworks at eval time.

  allVlanIds = lib.mapAttrsToList (_: net: net.vlanId) rawNetworks;
  dupVlanIds = let
    counts =
      lib.foldl' (
        acc: id:
          acc // {${toString id} = (acc.${toString id} or 0) + 1;}
      ) {}
      allVlanIds;
  in
    lib.filterAttrs (_: c: c > 1) counts;

  allHostnames =
    lib.concatMap
    (net: builtins.attrNames net.hosts)
    (builtins.attrValues rawNetworks);
  dupHostnames = let
    counts =
      lib.foldl' (
        acc: name:
          acc // {${name} = (acc.${name} or 0) + 1;}
      ) {}
      allHostnames;
  in
    lib.filterAttrs (_: c: c > 1) counts;

  validate = let
    # Duplicate VLAN IDs across zones
    vlanCheck =
      if dupVlanIds != {}
      then throw "network registry: duplicate VLAN IDs: ${builtins.toJSON dupVlanIds}"
      else true;

    # Duplicate hostnames across zones
    hostnameCheck =
      if dupHostnames != {}
      then throw "network registry: duplicate hostnames across zones: ${builtins.toJSON dupHostnames}"
      else true;

    # VLAN ID range (1-4094)
    vlanRangeCheck = lib.pipe rawNetworks [
      (lib.mapAttrsToList (zone: net:
        if net.vlanId < 1 || net.vlanId > 4094
        then throw "network registry: zone '${zone}' has invalid VLAN ID ${toString net.vlanId} (must be 1-4094)"
        else true))
      (builtins.all (x: x))
    ];

    # Host ID range — prefix-length-aware: max valid host ID = 2^(32-prefixLength4) - 2
    hostRangeCheck = lib.pipe rawNetworks [
      (lib.mapAttrsToList (zone: net: let
        prefixLength = net.prefixLength4 or 24;
        hostBits = 32 - prefixLength;
        maxId = (builtins.foldl' (a: _: a * 2) 1 (lib.range 1 hostBits)) - 2;
      in
        lib.mapAttrsToList (
          host: id:
            if id < 1 || id > maxId
            then throw "network registry: host '${host}' in zone '${zone}' has invalid ID ${toString id} (must be 1-${toString maxId} for /${toString prefixLength})"
            else true
        )
        net.hosts))
      lib.flatten
      (builtins.all (x: x))
    ];

    # Duplicate host IDs within a zone
    dupHostIdCheck = lib.pipe rawNetworks [
      (lib.mapAttrsToList (zone: net: let
        ids = builtins.attrValues net.hosts;
        unique = lib.unique ids;
      in
        if builtins.length ids != builtins.length unique
        then throw "network registry: zone '${zone}' has duplicate host IDs"
        else true))
      (builtins.all (x: x))
    ];

    # A zone may omit `gateway` only when both prefix4 and prefix6 are
    # overridden directly (transit zone uses this).
    gatewayCheck = lib.pipe rawNetworks [
      (lib.mapAttrsToList (zone: net:
        if !(net ? gateway) && !(net ? prefix4 && net ? prefix6)
        then throw "network registry: zone '${zone}' must set 'gateway', or override both 'prefix4' and 'prefix6'"
        else true))
      (builtins.all (x: x))
    ];
  in
    vlanCheck && hostnameCheck && vlanRangeCheck && hostRangeCheck && dupHostIdCheck && gatewayCheck;

  # Enhance each network with derived subnet and gateway addresses.
  # prefix4/prefix6 are derived from the gateway table unless explicitly overridden.
  # `gw` is lazy — only evaluated when a prefix needs derivation, so a zone
  # that overrides both prefixes can omit `gateway` entirely (gatewayCheck
  # in validate enforces this above).
  networks = assert validate;
    lib.mapAttrs (_: net: let
      gw =
        if net ? gateway
        then gateways.${net.gateway}
        else null;
      prefix4 = net.prefix4 or "${gw.prefix4}.${toString net.vlanId}";
      prefix6 = net.prefix6 or "${ulaPrefix}:${ulaSubnetHex gw.ulaGroup net.vlanId}";
      prefixLength4 = net.prefixLength4 or 24;
      prefixLength6 = net.prefixLength6 or 64;
    in
      net
      // {
        inherit prefix4 prefix6 prefixLength4 prefixLength6;
        subnet4 = "${prefix4}.0/${toString prefixLength4}";
        subnet6 = "${prefix6}::/${toString prefixLength6}";
        gateway4 = "${prefix4}.1";
        gateway6 = "${prefix6}::1";
      })
    rawNetworks;

  # Derive a full host record from network membership and host ID.
  # Uses per-zone prefix4/prefix6 and prefixLength so address derivation
  # is consistent with the networks enrichment above.
  mkHost = zoneName: vlanId: hostId: let
    zone = networks.${zoneName};
    inherit (zone) prefix4;
    inherit (zone) prefix6;
    inherit (zone) prefixLength4;
    inherit (zone) prefixLength6;
  in {
    inherit zoneName vlanId hostId;
    ipv4 = "${prefix4}.${toString hostId}";
    ipv6 = "${prefix6}::${hostHex hostId}";
    subnet4 = "${prefix4}.0/${toString prefixLength4}";
    subnet6 = "${prefix6}::/${toString prefixLength6}";
    cidr4 = "${prefix4}.${toString hostId}/${toString prefixLength4}";
    cidr6 = "${prefix6}::${hostHex hostId}/${toString prefixLength6}";
  };

  # Flatten networks into a single hosts attrset for direct lookup
  hosts =
    lib.concatMapAttrs (
      zoneName: net:
        lib.mapAttrs (_: hostId: mkHost zoneName net.vlanId hostId) net.hosts
    )
    networks;

  # WireGuard tunnel subnets.
  # All WG tunnels share the 10.100.x.x IPv4 space and fdc6:55f2:0a5e:64xx:: ULA space.
  # subnetId is both the IPv4 third octet and the lower two hex digits of the IPv6 segment.
  #   wg-ba:    subnetId=0  → 10.100.0.x/24,  fdc6:55f2:0a5e:6400::/64
  #   wg-vpn:   subnetId=10 → 10.100.10.x/24, fdc6:55f2:0a5e:640a::/64
  #   wg-media: subnetId=20 → 10.100.20.x/24, fdc6:55f2:0a5e:6414::/64
  rawWgNetworks = {
    "wg-ba" = {
      subnetId = 0;
      hosts = {remote = 3;};
    };
    "wg-vpn" = {
      subnetId = 10;
      hosts = {
        laptop = 20;
        mobile = 21;
      };
    };
    "wg-media" = {
      subnetId = 20;
      hosts = {arcus = 10;};
    };
  };

  wireguardNetworks =
    lib.mapAttrs (_: raw: let
      subnetHex = lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString raw.subnetId));
      prefix4 = "10.100.${toString raw.subnetId}";
      prefix6 = "${ulaPrefix}:64${subnetHex}";
    in {
      gateway4 = "${prefix4}.1";
      gateway6 = "${prefix6}::1";
      subnet4 = "${prefix4}.0/24";
      subnet6 = "${prefix6}::/64";
      hosts =
        lib.mapAttrs (_: id: {
          ipv4 = "${prefix4}.${toString id}";
          iface4 = "${prefix4}.${toString id}/24"; # interface address (with subnet prefix)
          cidr4 = "${prefix4}.${toString id}/32"; # peer allowedIPs (host route)
          ipv6 = "${prefix6}::${hostHex id}";
          iface6 = "${prefix6}::${hostHex id}/64"; # interface address (with subnet prefix)
          cidr6 = "${prefix6}::${hostHex id}/128"; # peer allowedIPs (host route)
        })
        raw.hosts;
    })
    rawWgNetworks;

  # Hosts that run fluent-bit-agent and push metrics/logs to tharbad.
  # Add a host here when enabling fluent-bit-agent in its NixOS config.
  monitoredHosts = let
    listed = [
      "thebeyond"
      "calvard"
      "erebonia"
      "liberl"
      "tharbad"
      "phantasma"
      "basel"
      "messeldam"
      "langport"
      "creil"
      "oracion"
      "zeiss"
      "bose"
      "ravennue"
      "roer"
    ];
    unknown = lib.filter (name: !(hosts ? ${name})) listed;
  in
    if unknown != []
    then throw "network registry: monitoredHosts: unknown hosts: ${lib.concatStringsSep ", " unknown}"
    else listed;

  # Hosts that should NOT receive authoritative internal DNS records
  # (<name>.internal[.mutantmell.net]). Empty by default — every registered
  # host resolves. Add a name here only when a host must intentionally lack an
  # A/AAAA record in the internal zone. Validated against the registry below.
  dnsExcludedHosts = [
    # bt8gw's only registry entry is in the transit /30 zone, so its record
    # would point at the point-to-point 10.255.255.2 — reachable only from
    # thebeyond's transit interface, not a general management path.
    "bt8gw"
  ];

  # Hosts served by phantasma's authoritative internal DNS zone. Derived from
  # the registry so a newly-added host resolves automatically — the previous
  # hand-maintained allow-list in dns.nix silently NXDOMAINed any host someone
  # forgot to add (this is how roer went missing). Subtract dnsExcludedHosts.
  dnsHosts = let
    unknown = lib.filter (name: !(hosts ? ${name})) dnsExcludedHosts;
  in
    if unknown != []
    then throw "network registry: dnsExcludedHosts: unknown hosts: ${lib.concatStringsSep ", " unknown}"
    else lib.filter (name: !(builtins.elem name dnsExcludedHosts)) (builtins.attrNames hosts);

  # Additional domain names per host, beyond the auto-derived
  # <name>.internal.mutantmell.net and <name>.internal.
  # These are the canonical source — dns.nix and mkExtraHosts reference this.
  hostAliases = {
    thebeyond = [
      "internal.mutantmell.net"
      "internal"
    ];
    messeldam = ["auth.mutantmell.net"];
    langport = ["mutantmell.net"];
    # Transition aliases: keep old DNS names resolving during migration
    liberl = [
      "remiferia.internal.mutantmell.net"
      "remiferia.internal"
    ];
    zeiss = [
      "attic.zeiss.internal.mutantmell.net"
      "attic.zeiss.internal"
      # Transition aliases
      "ardent.internal.mutantmell.net"
      "ardent.internal"
      "attic.ardent.internal.mutantmell.net"
      "attic.ardent.internal"
    ];
    tharbad = [
      "ntfy.internal.mutantmell.net"
      "ntfy.internal"
      "perses.internal.mutantmell.net"
      "perses.internal"
    ];
    oracion = [
      "jellyfin.internal.mutantmell.net"
      "jellyfin.internal"
      "navidrome.internal.mutantmell.net"
      "navidrome.internal"
      "retrom.internal.mutantmell.net"
      "retrom.internal"
    ];
    creil = [
      "forgejo.internal.mutantmell.net"
      "forgejo.internal"
    ];
  };

  # All domains a host is reachable by (bare hostname + FQDNs + aliases)
  domainsForHost = name:
    [name "${name}.internal.mutantmell.net" "${name}.internal"]
    ++ (hostAliases.${name} or []);

  # All hosts mapped to their domains (for batch lookups)
  allHostDomains = lib.mapAttrs (name: _: domainsForHost name) hosts;

  # Display/formatting helpers (summary tables, markdown docs)
  display = import ./network-display.nix {inherit lib hosts domainsForHost;};

  forHost = hostname: let
    h = hosts.${hostname} or (throw "Host '${hostname}' not found in network registry");
    z =
      networks.${h.zoneName} or (throw "Zone '${h.zoneName}' for host '${hostname}' not found in network registry");
  in {
    host = h;
    zone = z;
  };

  # mkExtraHosts: Generate /etc/hosts entries for a list of hostnames
  # Produces IPv4 and IPv6 lines with canonical, short, and alias names
  mkExtraHosts = hostnames:
    lib.concatMapStringsSep "\n" (name: let
      h = hosts.${name};
      domains = domainsForHost name;
      domainStr = lib.concatStringsSep " " domains;
    in
      lib.concatStringsSep "\n" (lib.filter (s: s != "") [
        (lib.optionalString (h ? ipv4) "${h.ipv4} ${domainStr}")
        (lib.optionalString (h ? ipv6) "${h.ipv6} ${domainStr}")
      ]))
    hostnames;

  # mkUnboundLocalData: Generate Unbound local-data entries (A + AAAA)
  # Produces canonical (.internal.mutantmell.net) and short alias (.internal) records
  mkUnboundLocalData = hostnames:
    lib.concatMap (name: let
      h = hosts.${name};
    in
      lib.filter (s: s != "") [
        (lib.optionalString (h ? ipv4) ''"${name}.internal.mutantmell.net. A ${h.ipv4}"'')
        (lib.optionalString (h ? ipv4) ''"${name}.internal. A ${h.ipv4}"'')
        (lib.optionalString (h ? ipv6) ''"${name}.internal.mutantmell.net. AAAA ${h.ipv6}"'')
        (lib.optionalString (h ? ipv6) ''"${name}.internal. AAAA ${h.ipv6}"'')
      ])
    hostnames;

  # mkUnboundAliasData: Generate Unbound local-data entries for host aliases
  # Produces A + AAAA records for each alias domain in hostAliases
  mkUnboundAliasData = hostnames:
    lib.concatMap (name: let
      h = hosts.${name};
      aliases = hostAliases.${name} or [];
    in
      lib.concatMap (alias:
        lib.filter (s: s != "") [
          (lib.optionalString (h ? ipv4) ''"${alias}. A ${h.ipv4}"'')
          (lib.optionalString (h ? ipv6) ''"${alias}. AAAA ${h.ipv6}"'')
        ])
      aliases)
    hostnames;

  # mkDualStackRules: Expand a firewall rule template into IPv4 + IPv6 rule pairs.
  # Takes a rule attrset where `saddr` and/or `daddr` are host records (with .ipv4/.ipv6).
  # Returns a list of two rules: one using ip.saddr/ip.daddr, one using ip6.saddr/ip6.daddr.
  # All other attributes are passed through unchanged (except comment gets " (v6)" suffix).
  # Usage:
  #   mkDualStackRules { saddr = tharbad; daddr = messeldam; tcp.dport = 443; verdict = "accept"; comment = "..."; }
  mkDualStackRules = rule: let
    hasSrc = rule ? saddr;
    hasDst = rule ? daddr;
    base = removeAttrs rule (["saddr" "daddr"] ++ lib.optional (rule ? comment) "comment");
    commentV4 = lib.optionalAttrs (rule ? comment) {inherit (rule) comment;};
    commentV6 = lib.optionalAttrs (rule ? comment) {comment = "${rule.comment} (v6)";};
    v4Addrs = lib.optionalAttrs (hasSrc || hasDst) {
      ip =
        lib.optionalAttrs hasSrc {saddr = rule.saddr.ipv4;}
        // lib.optionalAttrs hasDst {daddr = rule.daddr.ipv4;};
    };
    v6Addrs = lib.optionalAttrs (hasSrc || hasDst) {
      ip6 =
        lib.optionalAttrs hasSrc {saddr = rule.saddr.ipv6;}
        // lib.optionalAttrs hasDst {daddr = rule.daddr.ipv6;};
    };
  in [
    (base // v4Addrs // commentV4)
    (base // v6Addrs // commentV6)
  ];

  # Pre-computed /etc/hosts output for all registered hosts
  hostsFile = mkExtraHosts (builtins.attrNames hosts);

  # mkEgressRules: Expand host-based egress rules into dual-stack nftables strings
  # Each rule: { host OR gateway = true OR any = true; proto = "tcp"|"udp"; port = int|string; comment? = string; }
  # "gateway" uses the zone's gateway addresses instead of a host
  # "any" emits a single rule with no destination restriction
  mkEgressRules = zone: rules:
    lib.concatMap (
      rule: let
        port =
          if builtins.isList rule.port
          then "{ ${lib.concatMapStringsSep ", " toString rule.port} }"
          else toString rule.port;
        comment = lib.optionalString (rule ? comment) "  comment \"${rule.comment}\"";
      in
        if rule ? any && rule.any
        then ["${rule.proto} dport ${port} accept${comment}"]
        else let
          addrs =
            if rule ? gateway && rule.gateway
            then {
              v4 = zone.gateway4;
              v6 = zone.gateway6;
            }
            else if rule ? host
            then {
              v4 = hosts.${rule.host}.ipv4;
              v6 = hosts.${rule.host}.ipv6 or null;
            }
            else abort "mkEgressRules: rule must have 'gateway', 'host', or 'any'";
          v4 = "ip daddr ${addrs.v4} ${rule.proto} dport ${port} accept${comment}";
          v6 = "ip6 daddr ${addrs.v6} ${rule.proto} dport ${port} accept${comment}";
        in
          [v4]
          ++ lib.optional (addrs.v6 != null) v6
    )
    rules;
in {
  inherit
    networks
    wireguardNetworks
    ulaPrefix
    ulaSubnetHex
    gateways
    mkHost
    hosts
    hostAliases
    domainsForHost
    allHostDomains
    forHost
    mkExtraHosts
    mkUnboundLocalData
    mkUnboundAliasData
    mkEgressRules
    mkDualStackRules
    hostsFile
    monitoredHosts
    dnsHosts
    ;
  inherit
    (display)
    summary
    markdown
    hostinfoSummary
    hostinfoMarkdown
    ;
}
