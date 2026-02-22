{ lib }:
let
  ipv4Prefix = "10.0";
  ulaPrefix = "fdc6:55f2:0a5e";

  vlanHex = vlanId: lib.toLower (lib.toHexString vlanId);
  hostHex = hostId: lib.toLower (lib.toHexString hostId);

  # Network definitions — each network carries its zone, VLAN ID, and hosts.
  # Host values are host IDs (last octet / interface identifier).
  rawNetworks = {
    network = {
      vlanId = 10;
      hosts = {
        denali = 12;
      };
    };
    management = {
      vlanId = 11;
      hosts = {
        yggdrasil  = 1;
        alfheim    = 2;
        mimir      = 3;    # Keycloak OIDC
        tyr        = 4;    # step-ca / PKI
        jotunheimr = 20;   # NAS — before VM hosts
        vanaheim   = 30;   # VM host
        muspelheim = 31;   # VM host
      };
    };
    trusted = {
      vlanId = 20;
      hosts = {
        gridr = 30;
        skadi = 40;
        ymir  = 41;
      };
    };
    untrusted = {
      vlanId = 30;
      hosts = {};
    };
    adu = {
      vlanId = 31;
      hosts = {
        gumba = 20;
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
        hrungnir = 31;
        surtr    = 40;
        bragi    = 50;
        njord    = 51;
      };
    };
  };

  # Enhance each network with derived subnet and gateway addresses
  networks = lib.mapAttrs (_: net: net // {
    subnet4 = "${ipv4Prefix}.${toString net.vlanId}.0/24";
    subnet6 = "${ulaPrefix}:${vlanHex net.vlanId}::/64";
    gateway4 = "${ipv4Prefix}.${toString net.vlanId}.1";
    gateway6 = "${ulaPrefix}:${vlanHex net.vlanId}::1";
  }) rawNetworks;

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

  # Mesh hosts use a separate prefix (10.1.x.x) and are not yet migrated
  # to the zone-based addressing scheme.
  mkMeshHost = vlanId: hostId: {
    zoneName = "mesh";
    inherit vlanId hostId;
    ipv4 = "10.1.${toString vlanId}.${toString hostId}";
  };

  # Flatten networks into a single hosts attrset for direct lookup
  hosts = (lib.concatMapAttrs (zoneName: net:
    lib.mapAttrs (_: hostId: mkHost zoneName net.vlanId hostId) net.hosts
  ) networks) // {
    # Mesh hosts (10.1.x.x — separate prefix, not yet migrated)
    gumby      = mkMeshHost 10 20;
    pokey      = mkMeshHost 10 21;
    prickle    = mkMeshHost 10 22;
    goo        = mkMeshHost 10 23;
    gumbo      = mkMeshHost 10 24;
    nidavellir = mkMeshHost 20 50;
  };

  # Human-readable summary table
  pad = n: s: let
    padLen = n - builtins.stringLength s;
  in if padLen <= 0 then s else s + lib.fixedWidthString padLen " " "";

  header = "${pad 18 "Host"}${pad 18 "Zone"}${pad 18 "IPv4"}IPv6";
  separator = builtins.concatStringsSep "" (builtins.genList (_: "-") (builtins.stringLength header));

  row = name: h:
    "${pad 18 name}${pad 18 h.zoneName}${pad 18 h.ipv4}${h.ipv6 or ""}";

  hostList = lib.mapAttrsToList lib.nameValuePair hosts;
  hostsByZone = lib.groupBy (e: e.value.zoneName) hostList;

  renderZone = _zoneName: entries:
    lib.concatMapStringsSep "\n" (e: row e.name e.value) entries;

  summary = lib.concatStringsSep "\n\n" (
    [ header separator ]
    ++ lib.mapAttrsToList renderZone hostsByZone
  ) + "\n";

  # Markdown table for docs
  markdownRow = name: h:
    "| ${name} | ${h.zoneName} | `${h.ipv4}` | ${if h ? ipv6 then "`${h.ipv6}`" else ""} |";

  markdown = ''
    # Network Host Registry

    > **Auto-generated from `lib/common/data/network.nix`.** Do not edit manually.
    > Regenerate with: `nix run .#netinfo -- --generate-docs`

    | Host | Zone | IPv4 | IPv6 |
    |------|------|------|------|
  '' + lib.concatStringsSep "\n" (lib.mapAttrsToList markdownRow hosts) + "\n";

  forHost = hostname: let
    h = hosts.${hostname} or (throw "Host '${hostname}' not found in network registry");
    z = if networks ? ${h.zoneName} then networks.${h.zoneName}
        else throw "Zone '${h.zoneName}' for host '${hostname}' not found in network registry";
  in { host = h; zone = z; };

  # mkExtraHosts: Generate /etc/hosts entries for a list of hostnames
  # Produces both IPv4 and IPv6 lines for each host (if available)
  mkExtraHosts = hostnames:
    lib.concatMapStringsSep "\n" (name: let
      h = hosts.${name};
    in lib.concatStringsSep "\n" (lib.filter (s: s != "") [
      (lib.optionalString (h ? ipv4) "${h.ipv4} ${name}.local")
      (lib.optionalString (h ? ipv6) "${h.ipv6} ${name}.local")
    ])) hostnames;

  # mkUnboundLocalData: Generate Unbound local-data entries (A + AAAA)
  mkUnboundLocalData = hostnames:
    lib.concatMap (name: let
      h = hosts.${name};
    in lib.filter (s: s != "") [
      (lib.optionalString (h ? ipv4) ''"${name}.local. A ${h.ipv4}"'')
      (lib.optionalString (h ? ipv6) ''"${name}.local. AAAA ${h.ipv6}"'')
    ]) hostnames;

  # mkDualEgressRules: Expand host-based egress rules into dual-stack nftables strings
  # Each rule: { host OR gateway = true; proto = "tcp"|"udp"; port = int|string; comment? = string; }
  # "gateway" uses the zone's gateway addresses instead of a host
  mkDualEgressRules = zone: rules:
    lib.concatMap (rule: let
      addrs =
        if rule ? gateway && rule.gateway then { v4 = zone.gateway4; v6 = zone.gateway6; }
        else if rule ? host then { v4 = hosts.${rule.host}.ipv4; v6 = hosts.${rule.host}.ipv6 or null; }
        else abort "mkDualEgressRules: rule must have 'gateway' or 'host'";
      port = if builtins.isList rule.port
             then "{ ${lib.concatMapStringsSep ", " toString rule.port} }"
             else toString rule.port;
      comment = lib.optionalString (rule ? comment) "  comment \"${rule.comment}\"";
      v4 = "ip daddr ${addrs.v4} ${rule.proto} dport ${port} accept${comment}";
      v6 = "ip6 daddr ${addrs.v6} ${rule.proto} dport ${port} accept${comment}";
    in [ v4 ] ++ lib.optional (addrs.v6 != null) v6
    ) rules;

in {
  inherit networks ipv4Prefix ulaPrefix mkHost hosts summary markdown forHost
          mkExtraHosts mkUnboundLocalData mkDualEgressRules;
}
