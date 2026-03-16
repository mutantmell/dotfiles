# Network helper unit tests
#
# Pure Nix evaluation tests for mkExtraHosts, mkUnboundLocalData, mkEgressRules.
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
  # Primary (10.97) IPv4 + IPv6 lines
  extraHostsMesseldamCanonical = contains "10.97.11.6 messeldam messeldam.internal.mutantmell.net messeldam.internal" extraHostsBasic;
  extraHostsMesseldamV6Canonical = contains "fdc6:55f2:0a5e:b::6 messeldam messeldam.internal.mutantmell.net messeldam.internal" extraHostsBasic;
  extraHostsBaselCanonical = contains "10.97.11.7 basel basel.internal.mutantmell.net basel.internal" extraHostsBasic;
  extraHostsBaselV6Canonical = contains "fdc6:55f2:0a5e:b::7 basel basel.internal.mutantmell.net basel.internal" extraHostsBasic;
  extraHostsNoLegacy = !(contains "10.0." extraHostsBasic);

  # --- mkUnboundLocalData tests ---

  unboundBasic = net.mkUnboundLocalData ["phantasma" "langport"];
  # Canonical entries (primary 10.97)
  unboundPlantasmaA = builtins.elem ''"phantasma.internal.mutantmell.net. A ${net.hosts.phantasma.ipv4}"'' unboundBasic;
  unboundPlantasmaAAAA = builtins.elem ''"phantasma.internal.mutantmell.net. AAAA ${net.hosts.phantasma.ipv6}"'' unboundBasic;
  unboundLangportA = builtins.elem ''"langport.internal.mutantmell.net. A ${net.hosts.langport.ipv4}"'' unboundBasic;
  unboundLangportAAAA = builtins.elem ''"langport.internal.mutantmell.net. AAAA ${net.hosts.langport.ipv6}"'' unboundBasic;
  # Short alias entries
  unboundPlantasmaAShort = builtins.elem ''"phantasma.internal. A ${net.hosts.phantasma.ipv4}"'' unboundBasic;
  unboundPlantasmaAAAAShort = builtins.elem ''"phantasma.internal. AAAA ${net.hosts.phantasma.ipv6}"'' unboundBasic;
  unboundLangportAShort = builtins.elem ''"langport.internal. A ${net.hosts.langport.ipv4}"'' unboundBasic;
  unboundLangportAAAAShort = builtins.elem ''"langport.internal. AAAA ${net.hosts.langport.ipv6}"'' unboundBasic;
  unboundNoLegacy = builtins.length (builtins.filter (s: contains "10.0." s) unboundBasic) == 0;

  # Record count: 4 per dual-stack host (A+AAAA × canonical+short), 2 per host with only IPv4
  unboundDualStackCount = assertEq "unboundBasic length" (builtins.length unboundBasic) 8;

  # --- domainsForHost tests ---

  domainsBasel = net.domainsForHost "basel";
  domainsBaselBare =
    assertEq "domainsBasel has bare hostname"
    (builtins.elemAt domainsBasel 0) "basel";
  domainsBaselStandard =
    assertEq "domainsBasel has standard domains"
    (builtins.elemAt domainsBasel 1) "basel.internal.mutantmell.net";
  domainsBaselShort =
    assertEq "domainsBasel has short domain"
    (builtins.elemAt domainsBasel 2) "basel.internal";
  domainsBaselCount = assertEq "domainsBasel count" (builtins.length domainsBasel) 3;

  domainsMesseldam = net.domainsForHost "messeldam";
  domainsMesseldamCount = assertEq "domainsMesseldam count" (builtins.length domainsMesseldam) 4;
  domainsMesseldamAlias = builtins.elem "auth.mutantmell.net" domainsMesseldam;

  domainsThebeyond = net.domainsForHost "thebeyond";
  domainsThebeyondCount = assertEq "domainsThebeyond count" (builtins.length domainsThebeyond) 7;
  domainsThebeyondYggdrasil = builtins.elem "yggdrasil.internal.mutantmell.net" domainsThebeyond;
  domainsThebeyondInternal = builtins.elem "internal.mutantmell.net" domainsThebeyond;

  domainsAzoth = net.domainsForHost "azoth";
  domainsAzothCount = assertEq "domainsAzoth count" (builtins.length domainsAzoth) 3;

  # --- mkUnboundAliasData tests ---

  aliasDataMesseldam = net.mkUnboundAliasData ["messeldam"];
  aliasDataMesseldamA = builtins.elem ''"auth.mutantmell.net. A ${net.hosts.messeldam.ipv4}"'' aliasDataMesseldam;
  aliasDataMesseldamAAAA = builtins.elem ''"auth.mutantmell.net. AAAA ${net.hosts.messeldam.ipv6}"'' aliasDataMesseldam;
  # 1 alias × 2 records each (A + AAAA) = 2
  aliasDataMesseldamCount = assertEq "aliasDataMesseldam count" (builtins.length aliasDataMesseldam) 2;

  aliasDataThebeyond = net.mkUnboundAliasData ["thebeyond"];
  # 4 aliases × 2 records each (A + AAAA) = 8
  aliasDataThebeyondCount = assertEq "aliasDataThebeyond count" (builtins.length aliasDataThebeyond) 8;
  aliasDataThebeyondYggdrasil = builtins.elem ''"yggdrasil.internal.mutantmell.net. A ${net.hosts.thebeyond.ipv4}"'' aliasDataThebeyond;
  aliasDataThebeyondInternal = builtins.elem ''"internal.mutantmell.net. A ${net.hosts.thebeyond.ipv4}"'' aliasDataThebeyond;

  # Hosts with no aliases produce empty list
  aliasDataBasel = net.mkUnboundAliasData ["basel"];
  aliasDataBaselCount = assertEq "aliasDataBasel count" (builtins.length aliasDataBasel) 0;

  # --- mkHostsFileEntries tests ---

  hostsFileBasic = net.mkHostsFileEntries ["messeldam"];
  hostsFileMesseldamV4 = contains "10.97.11.6 messeldam messeldam.internal.mutantmell.net messeldam.internal auth.mutantmell.net" hostsFileBasic;
  hostsFileMesseldamV6 = contains "fdc6:55f2:0a5e:b::6 messeldam messeldam.internal.mutantmell.net messeldam.internal auth.mutantmell.net" hostsFileBasic;
  hostsFileNoLegacy = !(contains "10.0." hostsFileBasic);

  # --- mkExtraHosts includes aliases ---

  extraHostsWithAliases = net.mkExtraHosts ["messeldam"];
  extraHostsAliasIncluded = contains "auth.mutantmell.net" extraHostsWithAliases;

  # --- mkEgressRules tests ---

  mgmtZone = net.networks.management;
  dmzZone = net.networks.dmz;

  # Gateway rule produces v4 + v6
  gatewayRules = net.mkEgressRules mgmtZone [
    {
      gateway = true;
      proto = "udp";
      port = 53;
    }
  ];
  gatewayV4 = builtins.elem "ip daddr ${mgmtZone.gateway4} udp dport 53 accept" gatewayRules;
  gatewayV6 = builtins.elem "ip6 daddr ${mgmtZone.gateway6} udp dport 53 accept" gatewayRules;
  gatewayCount = assertEq "gatewayRules length" (builtins.length gatewayRules) 2;

  # Host rule produces v4 + v6 for hosts with IPv6
  hostRules = net.mkEgressRules dmzZone [
    {
      host = "basel";
      proto = "tcp";
      port = 443;
      comment = "ACME certs from basel";
    }
  ];
  hostV4 = builtins.elem ''ip daddr ${net.hosts.basel.ipv4} tcp dport 443 accept  comment "ACME certs from basel"'' hostRules;
  hostV6 = builtins.elem ''ip6 daddr ${net.hosts.basel.ipv6} tcp dport 443 accept  comment "ACME certs from basel"'' hostRules;
  hostCount = assertEq "hostRules length" (builtins.length hostRules) 2;

  # Multi-port rule: v4 + v6
  multiPortRules = net.mkEgressRules dmzZone [
    {
      host = "oracion";
      proto = "tcp";
      port = [80 443];
    }
  ];
  multiPortV4 = builtins.elem "ip daddr ${net.hosts.oracion.ipv4} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortV6 = builtins.elem "ip6 daddr ${net.hosts.oracion.ipv6} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortCount = assertEq "multiPortRules length" (builtins.length multiPortRules) 2;

  # Azoth is now a regular host with IPv6
  azothRules = net.mkEgressRules mgmtZone [
    {
      host = "azoth";
      proto = "tcp";
      port = 80;
    }
  ];
  azothCount = assertEq "azothRules length" (builtins.length azothRules) 2;
  azothV4Content = builtins.elem "ip daddr 10.97.20.50 tcp dport 80 accept" azothRules;

  allTests = {
    # mkExtraHosts
    "mkExtraHosts produces primary IPv4 for messeldam" = extraHostsMesseldamCanonical;
    "mkExtraHosts produces IPv6 for messeldam" = extraHostsMesseldamV6Canonical;
    "mkExtraHosts produces primary IPv4 for basel" = extraHostsBaselCanonical;
    "mkExtraHosts produces IPv6 for basel" = extraHostsBaselV6Canonical;
    "mkExtraHosts contains no legacy addresses" = extraHostsNoLegacy;

    # mkUnboundLocalData — canonical entries
    "mkUnboundLocalData produces canonical A for phantasma" = unboundPlantasmaA;
    "mkUnboundLocalData produces canonical AAAA for phantasma" = unboundPlantasmaAAAA;
    "mkUnboundLocalData produces canonical A for langport" = unboundLangportA;
    "mkUnboundLocalData produces canonical AAAA for langport" = unboundLangportAAAA;
    # mkUnboundLocalData — short alias entries
    "mkUnboundLocalData produces short A for phantasma" = unboundPlantasmaAShort;
    "mkUnboundLocalData produces short AAAA for phantasma" = unboundPlantasmaAAAAShort;
    "mkUnboundLocalData produces short A for langport" = unboundLangportAShort;
    "mkUnboundLocalData produces short AAAA for langport" = unboundLangportAAAAShort;
    # mkUnboundLocalData — counts + no legacy
    "mkUnboundLocalData contains no legacy addresses" = unboundNoLegacy;
    "mkUnboundLocalData dual-stack host produces 8 records" = unboundDualStackCount;

    # domainsForHost
    "domainsForHost returns bare hostname first" = domainsBaselBare;
    "domainsForHost returns standard canonical domain" = domainsBaselStandard;
    "domainsForHost returns standard short domain" = domainsBaselShort;
    "domainsForHost returns 3 domains for host without aliases" = domainsBaselCount;
    "domainsForHost returns 4 domains for messeldam (1 alias)" = domainsMesseldamCount;
    "domainsForHost includes auth.mutantmell.net for messeldam" = domainsMesseldamAlias;
    "domainsForHost returns 7 domains for thebeyond (4 aliases)" = domainsThebeyondCount;
    "domainsForHost includes yggdrasil alias for thebeyond" = domainsThebeyondYggdrasil;
    "domainsForHost includes internal alias for thebeyond" = domainsThebeyondInternal;
    "domainsForHost returns 3 domains for azoth" = domainsAzothCount;

    # mkUnboundAliasData
    "mkUnboundAliasData produces A for messeldam alias" = aliasDataMesseldamA;
    "mkUnboundAliasData produces AAAA for messeldam alias" = aliasDataMesseldamAAAA;
    "mkUnboundAliasData produces 2 records for messeldam (1 alias)" = aliasDataMesseldamCount;
    "mkUnboundAliasData produces 8 records for thebeyond (4 aliases)" = aliasDataThebeyondCount;
    "mkUnboundAliasData includes yggdrasil A record" = aliasDataThebeyondYggdrasil;
    "mkUnboundAliasData includes internal A record" = aliasDataThebeyondInternal;
    "mkUnboundAliasData produces 0 records for host without aliases" = aliasDataBaselCount;

    # mkHostsFileEntries
    "mkHostsFileEntries produces v4 with aliases for messeldam" = hostsFileMesseldamV4;
    "mkHostsFileEntries produces v6 with aliases for messeldam" = hostsFileMesseldamV6;
    "mkHostsFileEntries contains no legacy addresses" = hostsFileNoLegacy;

    # mkExtraHosts includes aliases
    "mkExtraHosts includes aliases in domain list" = extraHostsAliasIncluded;

    # mkEgressRules
    "mkEgressRules gateway produces v4" = gatewayV4;
    "mkEgressRules gateway produces v6" = gatewayV6;
    "mkEgressRules gateway produces 2 rules" = gatewayCount;
    "mkEgressRules host produces v4 with comment" = hostV4;
    "mkEgressRules host produces v6 with comment" = hostV6;
    "mkEgressRules host produces 2 rules" = hostCount;
    "mkEgressRules multi-port v4" = multiPortV4;
    "mkEgressRules multi-port v6" = multiPortV6;
    "mkEgressRules multi-port produces 2 rules" = multiPortCount;
    "mkEgressRules azoth produces 2 rules" = azothCount;
    "mkEgressRules azoth v4 content" = azothV4Content;
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
