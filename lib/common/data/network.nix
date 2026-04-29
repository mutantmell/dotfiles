{lib}: let
  ipv4Prefix = "10.97";
  ulaPrefix = "fdc6:55f2:0a5e";

  vlanHex = vlanId: lib.toLower (lib.toHexString vlanId);
  hostHex = hostId: lib.toLower (lib.toHexString hostId);

  # Network definitions — each network carries its zone, VLAN ID, and hosts.
  # Host values are host IDs (last octet / interface identifier).
  rawNetworks = {
    network = {
      vlanId = 10;
      hosts = {
        arseille = 12;
        merkabah = 20;
        derfflinger = 21;
        pantagruel = 22;
        bobcat = 23;
        lusitania = 24;
      };
    };
    management = {
      vlanId = 11;
      hosts = {
        thebeyond = 1;
        phantasma = 2;
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
      hosts = {
        azoth = 50; # Raspberry Pi (Home Assistant, MQTT)
      };
    };
    lab = {
      vlanId = 21;
      hosts = {
        edith = 42; # Dev environment / task runner (calvard Incus container)
        bose = 43; # Arr stack — Sonarr, Radarr, Bazarr (liberl)
      };
    };
    untrusted = {
      vlanId = 30;
      hosts = {
        arcus = 10; # Steam Deck (guest WiFi)
      };
    };
    adu = {
      vlanId = 31;
      hosts = {
        glorious = 20;
      };
    };
    iot = {
      vlanId = 40;
      hosts = {};
    };
    game = {
      vlanId = 41;
      hosts = {};
    };
    dmz = {
      vlanId = 100;
      hosts = {
        zeiss = 31; # Attic binary cache (liberl)
        trista = 51; # SSH bastion (erebonia Incus VM)
        langport = 41; # Reverse proxy (calvard)
        oracion = 52; # Jellyfin media server (calvard)
        creil = 53; # Forgejo git hosting (calvard)
        "saint-arkh" = 61; # Forgejo Actions CI/CD runners (erebonia)
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

    # Host ID range (1-254 for /24 subnets)
    hostRangeCheck = lib.pipe rawNetworks [
      (lib.mapAttrsToList (zone: net:
        lib.mapAttrsToList (
          host: id:
            if id < 1 || id > 254
            then throw "network registry: host '${host}' in zone '${zone}' has invalid ID ${toString id} (must be 1-254)"
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
  in
    vlanCheck && hostnameCheck && vlanRangeCheck && hostRangeCheck && dupHostIdCheck;

  # Enhance each network with derived subnet and gateway addresses
  networks = assert validate;
    lib.mapAttrs (_: net:
      net
      // {
        subnet4 = "${ipv4Prefix}.${toString net.vlanId}.0/24";
        subnet6 = "${ulaPrefix}:${vlanHex net.vlanId}::/64";
        prefixLength4 = 24;
        prefixLength6 = 64;
        gateway4 = "${ipv4Prefix}.${toString net.vlanId}.1";
        gateway6 = "${ulaPrefix}:${vlanHex net.vlanId}::1";
      })
    rawNetworks;

  # Derive a full host record from network membership and host ID
  mkHost = zoneName: vlanId: hostId: {
    inherit zoneName vlanId hostId;
    ipv4 = "${ipv4Prefix}.${toString vlanId}.${toString hostId}";
    ipv6 = "${ulaPrefix}:${vlanHex vlanId}::${hostHex hostId}";
    subnet4 = "${ipv4Prefix}.${toString vlanId}.0/24";
    subnet6 = "${ulaPrefix}:${vlanHex vlanId}::/64";
    cidr4 = "${ipv4Prefix}.${toString vlanId}.${toString hostId}/24";
    cidr6 = "${ulaPrefix}:${vlanHex vlanId}::${hostHex hostId}/64";
  };

  # Flatten networks into a single hosts attrset for direct lookup
  hosts =
    lib.concatMapAttrs (
      zoneName: net:
        lib.mapAttrs (_: hostId: mkHost zoneName net.vlanId hostId) net.hosts
    )
    networks;

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
      "saint-arkh"
      "trista"
      "bose"
      "edith"
      "roer"
    ];
    unknown = lib.filter (name: !(hosts ? ${name})) listed;
  in
    if unknown != []
    then throw "network registry: monitoredHosts: unknown hosts: ${lib.concatStringsSep ", " unknown}"
    else listed;

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
    ipv4Prefix
    ulaPrefix
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
    ;
  inherit
    (display)
    summary
    markdown
    hostinfoSummary
    hostinfoMarkdown
    ;
}
