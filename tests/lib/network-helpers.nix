# Network helper unit tests
#
# Pure Nix evaluation tests for mkExtraHosts, mkUnboundLocalData, mkDualEgressRules.
#
# Run: nix-instantiate --eval --strict tests/lib/network-helpers.nix
# Or:  nix build .#checks.x86_64-linux.network-helpers
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  net = import ../../lib/common/data/network.nix {inherit lib;};

  assertEq = name: a: b:
    if a == b
    then true
    else builtins.trace "FAIL: ${name}\n  expected: ${builtins.toJSON b}\n  got:      ${builtins.toJSON a}" false;

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  # --- mkExtraHosts tests ---

  extraHostsBasic = net.mkExtraHosts ["messeldam" "basel"];
  # Primary (10.97) and legacy (10.0) IPv4 + IPv6 lines
  extraHostsMesseldamCanonical = contains "10.97.11.6 messeldam.internal.mutantmell.net messeldam.internal" extraHostsBasic;
  extraHostsMesseldamLegacy = contains "10.0.11.6 messeldam.internal.mutantmell.net messeldam.internal" extraHostsBasic;
  extraHostsMesseldamV6Canonical = contains "fdc6:55f2:0a5e:b::6 messeldam.internal.mutantmell.net messeldam.internal" extraHostsBasic;
  extraHostsBaselCanonical = contains "10.97.11.7 basel.internal.mutantmell.net basel.internal" extraHostsBasic;
  extraHostsBaselLegacy = contains "10.0.11.7 basel.internal.mutantmell.net basel.internal" extraHostsBasic;
  extraHostsBaselV6Canonical = contains "fdc6:55f2:0a5e:b::7 basel.internal.mutantmell.net basel.internal" extraHostsBasic;

  # Mesh hosts have no IPv6 and no legacy — should produce only IPv4 line
  extraHostsMesh = net.mkExtraHosts ["azoth"];
  extraHostsMeshV4 = contains "10.1.20.50 azoth.internal.mutantmell.net azoth.internal" extraHostsMesh;
  extraHostsMeshNoV6 = !(contains "AAAA" extraHostsMesh || contains "fdc6" extraHostsMesh);
  extraHostsMeshNoLegacy = !(contains "10.0." extraHostsMesh || contains "10.97." extraHostsMesh);

  # --- mkUnboundLocalData tests ---

  unboundBasic = net.mkUnboundLocalData ["phantasma" "langport"];
  # Canonical entries (primary 10.97)
  unboundPlantasmaA = builtins.elem ''"phantasma.internal.mutantmell.net. A ${net.hosts.phantasma.ipv4}"'' unboundBasic;
  unboundPlantasmaALegacy = builtins.elem ''"phantasma.internal.mutantmell.net. A ${net.hosts.phantasma.ipv4Legacy}"'' unboundBasic;
  unboundPlantasmaAAAA = builtins.elem ''"phantasma.internal.mutantmell.net. AAAA ${net.hosts.phantasma.ipv6}"'' unboundBasic;
  unboundLangportA = builtins.elem ''"langport.internal.mutantmell.net. A ${net.hosts.langport.ipv4}"'' unboundBasic;
  unboundLangportALegacy = builtins.elem ''"langport.internal.mutantmell.net. A ${net.hosts.langport.ipv4Legacy}"'' unboundBasic;
  unboundLangportAAAA = builtins.elem ''"langport.internal.mutantmell.net. AAAA ${net.hosts.langport.ipv6}"'' unboundBasic;
  # Short alias entries
  unboundPlantasmaAShort = builtins.elem ''"phantasma.internal. A ${net.hosts.phantasma.ipv4}"'' unboundBasic;
  unboundPlantasmaAShortLegacy = builtins.elem ''"phantasma.internal. A ${net.hosts.phantasma.ipv4Legacy}"'' unboundBasic;
  unboundPlantasmaAAAAShort = builtins.elem ''"phantasma.internal. AAAA ${net.hosts.phantasma.ipv6}"'' unboundBasic;
  unboundLangportAShort = builtins.elem ''"langport.internal. A ${net.hosts.langport.ipv4}"'' unboundBasic;
  unboundLangportAShortLegacy = builtins.elem ''"langport.internal. A ${net.hosts.langport.ipv4Legacy}"'' unboundBasic;
  unboundLangportAAAAShort = builtins.elem ''"langport.internal. AAAA ${net.hosts.langport.ipv6}"'' unboundBasic;

  # Mesh hosts: A record only, no AAAA, no legacy (both canonical and short)
  unboundMesh = net.mkUnboundLocalData ["azoth"];
  unboundMeshA = builtins.elem ''"azoth.internal.mutantmell.net. A 10.1.20.50"'' unboundMesh;
  unboundMeshAShort = builtins.elem ''"azoth.internal. A 10.1.20.50"'' unboundMesh;
  unboundMeshNoAAAA = builtins.length (builtins.filter (s: contains "AAAA" s) unboundMesh) == 0;

  # Record count: 6 per dual-stack host (A+ALegacy+AAAA × canonical+short), 2 per mesh host (A × canonical+short)
  unboundDualStackCount = assertEq "unboundBasic length" (builtins.length unboundBasic) 12;
  unboundMeshCount = assertEq "unboundMesh length" (builtins.length unboundMesh) 2;

  # --- domainsForHost tests ---

  domainsBasel = net.domainsForHost "basel";
  domainsBaselStandard =
    assertEq "domainsBasel has standard domains"
    (builtins.elemAt domainsBasel 0) "basel.internal.mutantmell.net";
  domainsBaselShort =
    assertEq "domainsBasel has short domain"
    (builtins.elemAt domainsBasel 1) "basel.internal";
  domainsBaselCount = assertEq "domainsBasel count" (builtins.length domainsBasel) 2;

  domainsMesseldam = net.domainsForHost "messeldam";
  domainsMesseldamCount = assertEq "domainsMesseldam count" (builtins.length domainsMesseldam) 3;
  domainsMesseldamAlias = builtins.elem "auth.mutantmell.net" domainsMesseldam;

  domainsThebeyond = net.domainsForHost "thebeyond";
  domainsThebeyondCount = assertEq "domainsThebeyond count" (builtins.length domainsThebeyond) 6;
  domainsThebeyondYggdrasil = builtins.elem "yggdrasil.internal.mutantmell.net" domainsThebeyond;
  domainsThebeyondInternal = builtins.elem "internal.mutantmell.net" domainsThebeyond;

  domainsMesh = net.domainsForHost "azoth";
  domainsMeshCount = assertEq "domainsMesh count" (builtins.length domainsMesh) 2;

  # --- mkUnboundAliasData tests ---

  aliasDataMesseldam = net.mkUnboundAliasData ["messeldam"];
  aliasDataMesseldamA = builtins.elem ''"auth.mutantmell.net. A ${net.hosts.messeldam.ipv4}"'' aliasDataMesseldam;
  aliasDataMesseldamALegacy = builtins.elem ''"auth.mutantmell.net. A ${net.hosts.messeldam.ipv4Legacy}"'' aliasDataMesseldam;
  aliasDataMesseldamAAAA = builtins.elem ''"auth.mutantmell.net. AAAA ${net.hosts.messeldam.ipv6}"'' aliasDataMesseldam;
  aliasDataMesseldamCount = assertEq "aliasDataMesseldam count" (builtins.length aliasDataMesseldam) 3;

  aliasDataThebeyond = net.mkUnboundAliasData ["thebeyond"];
  # 4 aliases × 3 records each (A + ALegacy + AAAA) = 12
  aliasDataThebeyondCount = assertEq "aliasDataThebeyond count" (builtins.length aliasDataThebeyond) 12;
  aliasDataThebeyondYggdrasil = builtins.elem ''"yggdrasil.internal.mutantmell.net. A ${net.hosts.thebeyond.ipv4}"'' aliasDataThebeyond;
  aliasDataThebeyondInternal = builtins.elem ''"internal.mutantmell.net. A ${net.hosts.thebeyond.ipv4}"'' aliasDataThebeyond;

  # Hosts with no aliases produce empty list
  aliasDataBasel = net.mkUnboundAliasData ["basel"];
  aliasDataBaselCount = assertEq "aliasDataBasel count" (builtins.length aliasDataBasel) 0;

  # Mesh hosts with no aliases produce empty list
  aliasDataMesh = net.mkUnboundAliasData ["azoth"];
  aliasDataMeshCount = assertEq "aliasDataMesh count" (builtins.length aliasDataMesh) 0;

  # --- mkHostsFileEntries tests ---

  hostsFileBasic = net.mkHostsFileEntries ["messeldam"];
  hostsFileMesseldamV4 = contains "10.97.11.6 messeldam.internal.mutantmell.net messeldam.internal auth.mutantmell.net" hostsFileBasic;
  hostsFileMesseldamLegacy = contains "10.0.11.6 messeldam.internal.mutantmell.net messeldam.internal auth.mutantmell.net" hostsFileBasic;
  hostsFileMesseldamV6 = contains "fdc6:55f2:0a5e:b::6 messeldam.internal.mutantmell.net messeldam.internal auth.mutantmell.net" hostsFileBasic;

  hostsFileMesh = net.mkHostsFileEntries ["azoth"];
  hostsFileMeshV4 = contains "10.1.20.50 azoth.internal.mutantmell.net azoth.internal" hostsFileMesh;
  hostsFileMeshNoV6 = !(contains "fdc6" hostsFileMesh);

  # --- mkExtraHosts includes aliases ---

  extraHostsWithAliases = net.mkExtraHosts ["messeldam"];
  extraHostsAliasIncluded = contains "auth.mutantmell.net" extraHostsWithAliases;

  # --- mkDualEgressRules tests ---

  mgmtZone = net.networks.management;
  dmzZone = net.networks.dmz;

  # Gateway rule produces v4 + v4Legacy + v6
  gatewayRules = net.mkDualEgressRules mgmtZone [
    {
      gateway = true;
      proto = "udp";
      port = 53;
    }
  ];
  gatewayV4 = builtins.elem "ip daddr ${mgmtZone.gateway4} udp dport 53 accept" gatewayRules;
  gatewayV4Legacy = builtins.elem "ip daddr ${mgmtZone.gateway4Legacy} udp dport 53 accept" gatewayRules;
  gatewayV6 = builtins.elem "ip6 daddr ${mgmtZone.gateway6} udp dport 53 accept" gatewayRules;
  gatewayCount = assertEq "gatewayRules length" (builtins.length gatewayRules) 3;

  # Host rule produces v4 + v4Legacy + v6 for hosts with IPv6 and legacy
  hostRules = net.mkDualEgressRules dmzZone [
    {
      host = "basel";
      proto = "tcp";
      port = 443;
      comment = "ACME certs from basel";
    }
  ];
  hostV4 = builtins.elem ''ip daddr ${net.hosts.basel.ipv4} tcp dport 443 accept  comment "ACME certs from basel"'' hostRules;
  hostV4Legacy = builtins.elem ''ip daddr ${net.hosts.basel.ipv4Legacy} tcp dport 443 accept  comment "ACME certs from basel"'' hostRules;
  hostV6 = builtins.elem ''ip6 daddr ${net.hosts.basel.ipv6} tcp dport 443 accept  comment "ACME certs from basel"'' hostRules;
  hostCount = assertEq "hostRules length" (builtins.length hostRules) 3;

  # Host rule for mesh host (no IPv6, no legacy) produces v4 only
  meshRules = net.mkDualEgressRules mgmtZone [
    {
      host = "azoth";
      proto = "tcp";
      port = 80;
    }
  ];
  meshV4Only = assertEq "meshRules length" (builtins.length meshRules) 1;
  meshV4Content = builtins.elem "ip daddr 10.1.20.50 tcp dport 80 accept" meshRules;

  # Multi-port rule: v4 + v4Legacy + v6
  multiPortRules = net.mkDualEgressRules dmzZone [
    {
      host = "oracion";
      proto = "tcp";
      port = [80 443];
    }
  ];
  multiPortV4 = builtins.elem "ip daddr ${net.hosts.oracion.ipv4} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortV4Legacy = builtins.elem "ip daddr ${net.hosts.oracion.ipv4Legacy} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortV6 = builtins.elem "ip6 daddr ${net.hosts.oracion.ipv6} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortCount = assertEq "multiPortRules length" (builtins.length multiPortRules) 3;

  allTests = {
    # mkExtraHosts
    "mkExtraHosts produces primary IPv4 for messeldam" = extraHostsMesseldamCanonical;
    "mkExtraHosts produces legacy IPv4 for messeldam" = extraHostsMesseldamLegacy;
    "mkExtraHosts produces IPv6 for messeldam" = extraHostsMesseldamV6Canonical;
    "mkExtraHosts produces primary IPv4 for basel" = extraHostsBaselCanonical;
    "mkExtraHosts produces legacy IPv4 for basel" = extraHostsBaselLegacy;
    "mkExtraHosts produces IPv6 for basel" = extraHostsBaselV6Canonical;
    "mkExtraHosts produces IPv4 for mesh host" = extraHostsMeshV4;
    "mkExtraHosts skips IPv6 for mesh host" = extraHostsMeshNoV6;
    "mkExtraHosts skips legacy for mesh host" = extraHostsMeshNoLegacy;

    # mkUnboundLocalData — canonical entries
    "mkUnboundLocalData produces canonical A for phantasma" = unboundPlantasmaA;
    "mkUnboundLocalData produces canonical A legacy for phantasma" = unboundPlantasmaALegacy;
    "mkUnboundLocalData produces canonical AAAA for phantasma" = unboundPlantasmaAAAA;
    "mkUnboundLocalData produces canonical A for langport" = unboundLangportA;
    "mkUnboundLocalData produces canonical A legacy for langport" = unboundLangportALegacy;
    "mkUnboundLocalData produces canonical AAAA for langport" = unboundLangportAAAA;
    # mkUnboundLocalData — short alias entries
    "mkUnboundLocalData produces short A for phantasma" = unboundPlantasmaAShort;
    "mkUnboundLocalData produces short A legacy for phantasma" = unboundPlantasmaAShortLegacy;
    "mkUnboundLocalData produces short AAAA for phantasma" = unboundPlantasmaAAAAShort;
    "mkUnboundLocalData produces short A for langport" = unboundLangportAShort;
    "mkUnboundLocalData produces short A legacy for langport" = unboundLangportAShortLegacy;
    "mkUnboundLocalData produces short AAAA for langport" = unboundLangportAAAAShort;
    # mkUnboundLocalData — mesh + counts
    "mkUnboundLocalData produces canonical A for mesh host" = unboundMeshA;
    "mkUnboundLocalData produces short A for mesh host" = unboundMeshAShort;
    "mkUnboundLocalData skips AAAA for mesh host" = unboundMeshNoAAAA;
    "mkUnboundLocalData dual-stack host produces 12 records" = unboundDualStackCount;
    "mkUnboundLocalData mesh host produces 2 records" = unboundMeshCount;

    # domainsForHost
    "domainsForHost returns standard canonical domain" = domainsBaselStandard;
    "domainsForHost returns standard short domain" = domainsBaselShort;
    "domainsForHost returns 2 domains for host without aliases" = domainsBaselCount;
    "domainsForHost returns 3 domains for messeldam (1 alias)" = domainsMesseldamCount;
    "domainsForHost includes auth.mutantmell.net for messeldam" = domainsMesseldamAlias;
    "domainsForHost returns 6 domains for thebeyond (4 aliases)" = domainsThebeyondCount;
    "domainsForHost includes yggdrasil alias for thebeyond" = domainsThebeyondYggdrasil;
    "domainsForHost includes internal alias for thebeyond" = domainsThebeyondInternal;
    "domainsForHost returns 2 domains for mesh host" = domainsMeshCount;

    # mkUnboundAliasData
    "mkUnboundAliasData produces A for messeldam alias" = aliasDataMesseldamA;
    "mkUnboundAliasData produces A legacy for messeldam alias" = aliasDataMesseldamALegacy;
    "mkUnboundAliasData produces AAAA for messeldam alias" = aliasDataMesseldamAAAA;
    "mkUnboundAliasData produces 3 records for messeldam (1 alias)" = aliasDataMesseldamCount;
    "mkUnboundAliasData produces 12 records for thebeyond (4 aliases)" = aliasDataThebeyondCount;
    "mkUnboundAliasData includes yggdrasil A record" = aliasDataThebeyondYggdrasil;
    "mkUnboundAliasData includes internal A record" = aliasDataThebeyondInternal;
    "mkUnboundAliasData produces 0 records for host without aliases" = aliasDataBaselCount;
    "mkUnboundAliasData produces 0 records for mesh host without aliases" = aliasDataMeshCount;

    # mkHostsFileEntries
    "mkHostsFileEntries produces v4 with aliases for messeldam" = hostsFileMesseldamV4;
    "mkHostsFileEntries produces legacy v4 with aliases for messeldam" = hostsFileMesseldamLegacy;
    "mkHostsFileEntries produces v6 with aliases for messeldam" = hostsFileMesseldamV6;
    "mkHostsFileEntries produces v4 for mesh host" = hostsFileMeshV4;
    "mkHostsFileEntries skips v6 for mesh host" = hostsFileMeshNoV6;

    # mkExtraHosts includes aliases
    "mkExtraHosts includes aliases in domain list" = extraHostsAliasIncluded;

    # mkDualEgressRules
    "mkDualEgressRules gateway produces v4" = gatewayV4;
    "mkDualEgressRules gateway produces v4 legacy" = gatewayV4Legacy;
    "mkDualEgressRules gateway produces v6" = gatewayV6;
    "mkDualEgressRules gateway produces 3 rules" = gatewayCount;
    "mkDualEgressRules host produces v4 with comment" = hostV4;
    "mkDualEgressRules host produces v4 legacy with comment" = hostV4Legacy;
    "mkDualEgressRules host produces v6 with comment" = hostV6;
    "mkDualEgressRules host produces 3 rules" = hostCount;
    "mkDualEgressRules mesh host produces only v4" = meshV4Only;
    "mkDualEgressRules mesh host v4 content" = meshV4Content;
    "mkDualEgressRules multi-port v4" = multiPortV4;
    "mkDualEgressRules multi-port v4 legacy" = multiPortV4Legacy;
    "mkDualEgressRules multi-port v6" = multiPortV6;
    "mkDualEgressRules multi-port produces 3 rules" = multiPortCount;
  };

  failures = lib.filterAttrs (_: v: !v) allTests;
  failCount = builtins.length (builtins.attrNames failures);
  passCount = builtins.length (builtins.attrNames allTests) - failCount;
in
  if failCount > 0
  then
    builtins.throw "network-helpers: ${toString failCount} test(s) failed:\n${
      lib.concatMapStringsSep "\n" (name: "  FAIL: ${name}") (builtins.attrNames failures)
    }"
  else
    pkgs.runCommand "network-helpers-tests" {} ''
      echo "network-helpers: ${toString passCount}/${toString passCount} tests passed"
      echo passed > $out
    ''
