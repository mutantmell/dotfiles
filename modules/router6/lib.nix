# Router6 internal helper library
#
# Shared helpers used across router6 sub-modules.
# Not a NixOS module — imported as a plain Nix expression.
{
  cfg,
  lib,
}: let
  # nftables DSL library for structured rule generation
  nft = import ../../lib/nftables.nix {inherit lib;};
  inherit
    (lib)
    optional
    optionals
    mapAttrs
    mapAttrsToList
    filterAttrs
    optionalAttrs
    optionalString
    concatStringsSep
    flatten
    filter
    elem
    splitString
    toInt
    any
    ;
  inherit (builtins) attrNames attrValues hasAttr length head elemAt;

  # Loopback port kresd retreats to when Blocky (dns-blocking.nix) is placed in
  # front of it. Internal plumbing between the two services on the router — not
  # a user knob (the DSL is opinionated). DNS is always served on :53 at the
  # router; enabling blocking only changes which service binds :53 directly
  # (Blocky) vs. the loopback backend (kresd). 5335 (not 5353) deliberately
  # avoids the mDNS port.
  blockingBackendPort = 5335;

  # ============================================================================
  # Device Kind Queries
  # ============================================================================

  devicesByKind = kind: filterAttrs (n: v: v.kind == kind) cfg.topology;

  # ============================================================================
  # Bond/Bridge Membership
  # ============================================================================

  isMember = kind: devName:
    any (container: elem devName (container.members or []))
    (attrValues (devicesByKind kind));

  findContaining = kind: member: let
    containers =
      filter (c: elem member (c.members or []))
      (mapAttrsToList (n: v: v // {name = n;}) (devicesByKind kind));
    count = length containers;
  in
    if count == 0
    then null
    else if count == 1
    then (head containers).name
    else throw "Device '${member}' is in multiple ${kind}s: ${concatStringsSep ", " (map (c: c.name) containers)}. Each device can only be in one ${kind}.";

  # ============================================================================
  # Topology Processing
  # ============================================================================

  flattenTopology = let
    flattenDevice = name: device: let
      baseInterface = {
        inherit name;
        network = device.network or {type = "disabled";};
        inherit (device) kind;
        isVlan = false;
        parent = null;
        tag = null;
        isBridge = device.kind == "bridge";
        isBond = device.kind == "bond";
      };
      vlans = mapAttrsToList (vlanName: vlan: {
        name = vlanName;
        network =
          if isMember "bridge" vlanName && vlan.network.type != "disabled"
          then throw "vlan cannot be a member of a bridge and have a network"
          else vlan.network;
        isVlan = true;
        parent = name;
        inherit (vlan) tag;
        bridge =
          if isMember "bridge" vlanName
          then findContaining "bridge" vlanName
          else null;
        kind = "vlan";
        isBridge = false;
        isBond = false;
      }) (device.vlans or {});
    in
      [baseInterface] ++ vlans;
  in
    flatten (mapAttrsToList flattenDevice cfg.topology);

  interfacesWhere = pred: map (i: i.name) (filter pred flattenTopology);

  interfacesInZone = zoneName:
    interfacesWhere (i: (i.network.zone or null) == zoneName);

  zonesInterfaces = zoneNames:
    lib.unique (lib.concatMap interfacesInZone zoneNames);

  activeZones = filter (z: interfacesInZone z != []) (attrNames cfg.zones);

  raInterfaces =
    interfacesWhere (i:
      i.network.type == "dhcp" || (i.network.ipv6PrefixDelegation.enable or false));

  zoneAllowsDns = zoneName: let
    zone = cfg.zones.${zoneName};
    portMatchesDns = dp: dp == 53 || (lib.isList dp && elem 53 dp);
    ruleAllowsDns = rule:
      if lib.isAttrs rule
      then
        ((rule ? verdict)
          && rule.verdict == "accept"
          && !(rule ? tcp)
          && !(rule ? udp))
        || ((rule ? udp) && portMatchesDns (rule.udp.dport or null))
        || ((rule ? tcp) && portMatchesDns (rule.tcp.dport or null))
      else true;
  in
    any ruleAllowsDns zone.inputRules;

  dnsInterfaces = interfacesWhere (i: let
    z = i.network.zone or null;
  in
    z != null && hasAttr z cfg.zones && zoneAllowsDns z);

  dhcpServerInterfaces = interfacesWhere (i: i.network.dhcp.enable or false);

  natInterfaces = interfacesWhere (i: i.network.nat.enable or false);

  # ============================================================================
  # Address Generation & Parsing
  # ============================================================================

  parseIPAddress = ipStr: let
    v6 = lib.hasInfix ":" ipStr;
  in {
    ip = ipStr;
    isV6 = v6;
    parts =
      if v6
      then splitString ":" ipStr
      else splitString "." ipStr;
    networkPrefix =
      if v6
      then "${head (splitString "::" ipStr)}::"
      else null;
  };

  parseCIDR = cidrStr: let
    parts = splitString "/" cidrStr;
  in
    if length parts != 2
    then throw "Invalid CIDR address '${cidrStr}' - must be in format 'ip/prefix'"
    else let
      addr = parseIPAddress (head parts);
      prefix = toInt (elemAt parts 1);
    in {
      cidr = cidrStr;
      inherit addr prefix;
      inherit (addr) ip isV6 networkPrefix;
      networkAddr =
        if addr.isV6
        then null
        else let
          o = map toInt addr.parts;
        in "${toString (elemAt o 0)}.${toString (elemAt o 1)}.${toString (elemAt o 2)}.0";
      poolStart =
        if addr.isV6
        then null
        else "${elemAt addr.parts 0}.${elemAt addr.parts 1}.${elemAt addr.parts 2}.100";
      poolEnd =
        if addr.isV6
        then null
        else "${elemAt addr.parts 0}.${elemAt addr.parts 1}.${elemAt addr.parts 2}.200";
      gateway = addr.ip;
    };

  # Address family helpers
  isV6 = a: a.isV6;
  isV4 = a: !a.isV6;
  partitionAF = addrs: {
    all = addrs;
    v4 = filter isV4 addrs;
    v6 = filter isV6 addrs;
  };

  firstIPv4 = addrs: let
    v4 = filter isV4 addrs;
  in
    if v4 == []
    then null
    else head v4;

  firstIPv6 = addrs: let
    v6 = filter isV6 addrs;
  in
    if v6 == []
    then null
    else head v6;

  mkAutoIPv6 = vlanTag:
    if cfg.ulaPrefix != null
    then let
      basePrefix = lib.removeSuffix "::/48" cfg.ulaPrefix;
      vlanHex = lib.toLower (lib.toHexString vlanTag);
    in "${basePrefix}:${vlanHex}::1/64"
    else null;

  getEffectiveAddresses = iface:
    if iface == null
    then []
    else let
      explicit = iface.network.addresses or [];
      hasExplicitV6 = any (a: lib.hasInfix ":" a) explicit;
      subnetId =
        if (iface.network.subnetId or null) != null
        then iface.network.subnetId
        else (iface.tag or null);
      autoV6 =
        if !hasExplicitV6 && (iface.network.dhcp6.enable or false) && subnetId != null
        then mkAutoIPv6 subnetId
        else null;
      allAddrs = explicit ++ (optional (autoV6 != null) autoV6);
    in
      map parseCIDR allAddrs;

  ipv4ToInt = ipStr: let
    octets = splitString "." ipStr;
  in
    (toInt (elemAt octets 0))
    * 16777216
    + (toInt (elemAt octets 1)) * 65536
    + (toInt (elemAt octets 2)) * 256
    + (toInt (elemAt octets 3));

  # ============================================================================
  # Kea DHCP Subnet Builders
  # ============================================================================

  mkKeaSubnet4 = iface: let
    parsed = firstIPv4 (getEffectiveAddresses iface);
    dhcpCfg = iface.network.dhcp;
  in
    if parsed == null
    then null
    else let
      poolStart =
        if dhcpCfg.poolStart != null
        then dhcpCfg.poolStart
        else parsed.poolStart;
      poolEnd =
        if dhcpCfg.poolEnd != null
        then dhcpCfg.poolEnd
        else parsed.poolEnd;
      subnetId = ipv4ToInt parsed.networkAddr;
    in {
      id = subnetId;
      subnet = "${parsed.networkAddr}/${toString parsed.prefix}";
      pools = [
        {
          pool = "${poolStart} - ${poolEnd}";
        }
      ];
      option-data =
        [
          {
            name = "routers";
            data = parsed.gateway;
          }
          {
            name = "domain-name-servers";
            data = parsed.gateway;
          }
        ]
        ++ optional (cfg.dns.localDomain != null) {
          name = "domain-name";
          data = cfg.dns.localDomain;
        };
      reservations = map (r:
        {
          hw-address = r.mac;
          ip-address = r.ip;
        }
        // optionalAttrs (r.hostname != null) {
          inherit (r) hostname;
        }) (dhcpCfg.reservations or []);
    };

  keaSubnets =
    filter (x: x != null) (map mkKeaSubnet4
      (filter (i: i.network.dhcp.enable or false) flattenTopology));

  mkKeaSubnet6 = iface: let
    effectiveAddrs = getEffectiveAddresses iface;
    parsed = firstIPv6 effectiveAddrs;
    dhcp6Cfg = iface.network.dhcp6;
  in
    if parsed == null
    then null
    else let
      subnetIdNum =
        if (iface.network.subnetId or null) != null
        then iface.network.subnetId
        else (iface.tag or 1);
    in {
      id = 100000 + subnetIdNum;
      subnet = "${parsed.networkPrefix}/${toString parsed.prefix}";
      interface = iface.name;
      pools =
        if dhcp6Cfg.mode == "stateful"
        then [
          {
            pool = "${parsed.networkPrefix}1000-${parsed.networkPrefix}1fff";
          }
        ]
        else [];
      option-data =
        [
          {
            name = "dns-servers";
            data = parsed.ip;
          }
        ]
        ++ optional (cfg.dns.localDomain != null) {
          name = "domain-search";
          data = cfg.dns.localDomain;
        };
    };

  dhcp6ServerInterfaces =
    interfacesWhere (i:
      (i.network.dhcp6.enable or false) && (i.network.dhcp6.mode or "slaac") != "slaac");

  keaSubnets6 =
    filter (x: x != null) (map mkKeaSubnet6
      (filter (i: (i.network.dhcp6.enable or false) && (i.network.dhcp6.mode or "slaac") != "slaac") flattenTopology));

  # ============================================================================
  # nftables Helpers
  # ============================================================================

  concatSections = sections: let
    nonEmpty = filter (s: s != []) sections;
  in
    lib.concatLists (lib.intersperse [""] nonEmpty);

  renderSection = ind: rules:
    if rules == []
    then ""
    else "\n${ind}${nft.rulesToStringIndented ind rules}";
in {
  inherit
    # Topology
    devicesByKind
    isMember
    findContaining
    flattenTopology
    interfacesWhere
    interfacesInZone
    zonesInterfaces
    activeZones
    raInterfaces
    zoneAllowsDns
    dnsInterfaces
    dhcpServerInterfaces
    natInterfaces
    # DNS
    blockingBackendPort
    # Address parsing
    parseIPAddress
    parseCIDR
    isV6
    isV4
    partitionAF
    firstIPv4
    firstIPv6
    mkAutoIPv6
    getEffectiveAddresses
    ipv4ToInt
    # DHCP
    mkKeaSubnet4
    mkKeaSubnet6
    keaSubnets
    keaSubnets6
    dhcp6ServerInterfaces
    # nftables
    concatSections
    renderSection
    ;
}
