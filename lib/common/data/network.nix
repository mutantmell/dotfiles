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
        remiferia = 20; # NAS — before VM hosts
        calvard = 30; # VM host
        erebonia = 31; # VM host
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
      };
    };
    untrusted = {
      vlanId = 30;
      hosts = {};
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
        ardent = 31;
        trista = 51; # SSH bastion (erebonia Incus VM)
        langport = 41; # Reverse proxy (calvard)
        oracion = 52; # Jellyfin media server (calvard)
        creil = 53; # Forgejo git hosting (calvard)
        monrain = 32; # cgit bare repository hosting (remiferia)
        "saint-arkh" = 61; # Forgejo Actions CI/CD runners (erebonia)
      };
    };
  };

  # Enhance each network with derived subnet and gateway addresses
  networks = lib.mapAttrs (_: net:
    net
    // {
      subnet4 = "${ipv4Prefix}.${toString net.vlanId}.0/24";
      subnet6 = "${ulaPrefix}:${vlanHex net.vlanId}::/64";
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
    ardent = [
      "attic.ardent.internal.mutantmell.net"
      "attic.ardent.internal"
    ];
  };

  # All domains a host is reachable by (bare hostname + FQDNs + aliases)
  domainsForHost = name:
    [name "${name}.internal.mutantmell.net" "${name}.internal"]
    ++ (hostAliases.${name} or []);

  # All hosts mapped to their domains (for batch lookups)
  allHostDomains = lib.mapAttrs (name: _: domainsForHost name) hosts;

  # Human-readable summary table
  pad = n: s: let
    padLen = n - builtins.stringLength s;
  in
    if padLen <= 0
    then s
    else s + lib.fixedWidthString padLen " " "";

  header = "${pad 18 "Host"}${pad 18 "Zone"}${pad 18 "IPv4"}IPv6";
  separator = builtins.concatStringsSep "" (builtins.genList (_: "-") (builtins.stringLength header));

  row = name: h: "${pad 18 name}${pad 18 h.zoneName}${pad 18 h.ipv4}${h.ipv6 or ""}";

  hostList = lib.mapAttrsToList lib.nameValuePair hosts;
  hostsByZone = builtins.groupBy (e: e.value.zoneName) hostList;

  renderZone = _zoneName: entries:
    lib.concatMapStringsSep "\n" (e: row e.name e.value) entries;

  summary =
    lib.concatStringsSep "\n\n" (
      [header separator]
      ++ lib.mapAttrsToList renderZone hostsByZone
    )
    + "\n";

  # Markdown table for docs
  markdownRow = name: h: "| ${name} | ${h.zoneName} | `${h.ipv4}` | ${
    if h ? ipv6
    then "`${h.ipv6}`"
    else ""
  } |";

  markdown =
    ''
      # Network Host Registry

      > **Auto-generated from `lib/common/data/network.nix`.** Do not edit manually.
      > Regenerate with: `nix run .#netinfo -- --generate-docs`

      | Host | Zone | IPv4 | IPv6 |
      |------|------|------|------|
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList markdownRow hosts)
    + "\n";

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

  # --- hostinfo display helpers ---

  # Human-readable hostinfo summary table
  hostinfoPad = n: s: let
    padLen = n - builtins.stringLength s;
  in
    if padLen <= 0
    then s
    else s + lib.fixedWidthString padLen " " "";

  hostinfoHeader = "${hostinfoPad 18 "Host"}${hostinfoPad 18 "IPv4"}${hostinfoPad 45 "IPv6"}Domains";
  hostinfoSeparator = builtins.concatStringsSep "" (builtins.genList (_: "-") (builtins.stringLength hostinfoHeader));

  hostinfoRow = name: h: let
    domains = domainsForHost name;
  in "${hostinfoPad 18 name}${hostinfoPad 18 h.ipv4}${hostinfoPad 45 (h.ipv6 or "")}${lib.concatStringsSep ", " domains}";

  hostinfoList = lib.mapAttrsToList lib.nameValuePair hosts;
  hostinfoByZone = builtins.groupBy (e: e.value.zoneName) hostinfoList;

  hostinfoRenderZone = zoneName: entries:
    "# ${zoneName}\n"
    + lib.concatMapStringsSep "\n" (e: hostinfoRow e.name e.value) entries;

  hostinfoSummary =
    lib.concatStringsSep "\n\n" (
      [hostinfoHeader hostinfoSeparator]
      ++ lib.mapAttrsToList hostinfoRenderZone hostinfoByZone
    )
    + "\n";

  # Markdown table for hostinfo docs
  hostinfoMarkdownRow = name: h: let
    domains = domainsForHost name;
  in "| ${name} | `${h.ipv4}` | ${
    if h ? ipv6
    then "`${h.ipv6}`"
    else ""
  } | ${lib.concatStringsSep ", " (map (d: "`${d}`") domains)} |";

  hostinfoMarkdown =
    ''
      # Host Domain Registry

      > **Auto-generated from `lib/common/data/network.nix`.** Do not edit manually.
      > Regenerate with: `nix run .#hostinfo -- --generate-docs`

      | Host | IPv4 | IPv6 | Domains |
      |------|------|------|---------|
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList hostinfoMarkdownRow hosts)
    + "\n";

  # /etc/hosts format — one line per IP, with all domains for that host
  mkHostsFileEntries = hostnames:
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

  # Pre-computed /etc/hosts output for all registered hosts
  hostsFile = mkHostsFileEntries (builtins.attrNames hosts);

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
    summary
    markdown
    forHost
    mkExtraHosts
    mkUnboundLocalData
    mkUnboundAliasData
    mkEgressRules
    hostinfoSummary
    hostinfoMarkdown
    mkHostsFileEntries
    hostsFile
    ;
}
