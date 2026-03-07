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

  extraHostsBasic = net.mkExtraHosts ["roer" "legram"];
  # Primary (10.97) and legacy (10.0) IPv4 + IPv6 lines
  extraHostsRoerCanonical = contains "10.97.11.3 roer.internal.mutantmell.net roer.internal" extraHostsBasic;
  extraHostsRoerLegacy = contains "10.0.11.3 roer.internal.mutantmell.net roer.internal" extraHostsBasic;
  extraHostsRoerV6Canonical = contains "fdc6:55f2:0a5e:b::3 roer.internal.mutantmell.net roer.internal" extraHostsBasic;
  extraHostsLegramCanonical = contains "10.97.11.4 legram.internal.mutantmell.net legram.internal" extraHostsBasic;
  extraHostsLegramLegacy = contains "10.0.11.4 legram.internal.mutantmell.net legram.internal" extraHostsBasic;
  extraHostsLegramV6Canonical = contains "fdc6:55f2:0a5e:b::4 legram.internal.mutantmell.net legram.internal" extraHostsBasic;

  # Mesh hosts have no IPv6 and no legacy — should produce only IPv4 line
  extraHostsMesh = net.mkExtraHosts ["azoth"];
  extraHostsMeshV4 = contains "10.1.20.50 azoth.internal.mutantmell.net azoth.internal" extraHostsMesh;
  extraHostsMeshNoV6 = !(contains "AAAA" extraHostsMesh || contains "fdc6" extraHostsMesh);
  extraHostsMeshNoLegacy = !(contains "10.0." extraHostsMesh || contains "10.97." extraHostsMesh);

  # --- mkUnboundLocalData tests ---

  unboundBasic = net.mkUnboundLocalData ["phantasma" "ordis"];
  # Canonical entries (primary 10.97)
  unboundPlantasmaA = builtins.elem ''"phantasma.internal.mutantmell.net. A ${net.hosts.phantasma.ipv4}"'' unboundBasic;
  unboundPlantasmaALegacy = builtins.elem ''"phantasma.internal.mutantmell.net. A ${net.hosts.phantasma.ipv4Legacy}"'' unboundBasic;
  unboundPlantasmaAAAA = builtins.elem ''"phantasma.internal.mutantmell.net. AAAA ${net.hosts.phantasma.ipv6}"'' unboundBasic;
  unboundOrdisA = builtins.elem ''"ordis.internal.mutantmell.net. A ${net.hosts.ordis.ipv4}"'' unboundBasic;
  unboundOrdisALegacy = builtins.elem ''"ordis.internal.mutantmell.net. A ${net.hosts.ordis.ipv4Legacy}"'' unboundBasic;
  unboundOrdisAAAA = builtins.elem ''"ordis.internal.mutantmell.net. AAAA ${net.hosts.ordis.ipv6}"'' unboundBasic;
  # Short alias entries
  unboundPlantasmaAShort = builtins.elem ''"phantasma.internal. A ${net.hosts.phantasma.ipv4}"'' unboundBasic;
  unboundPlantasmaAShortLegacy = builtins.elem ''"phantasma.internal. A ${net.hosts.phantasma.ipv4Legacy}"'' unboundBasic;
  unboundPlantasmaAAAAShort = builtins.elem ''"phantasma.internal. AAAA ${net.hosts.phantasma.ipv6}"'' unboundBasic;
  unboundOrdisAShort = builtins.elem ''"ordis.internal. A ${net.hosts.ordis.ipv4}"'' unboundBasic;
  unboundOrdisAShortLegacy = builtins.elem ''"ordis.internal. A ${net.hosts.ordis.ipv4Legacy}"'' unboundBasic;
  unboundOrdisAAAAShort = builtins.elem ''"ordis.internal. AAAA ${net.hosts.ordis.ipv6}"'' unboundBasic;

  # Mesh hosts: A record only, no AAAA, no legacy (both canonical and short)
  unboundMesh = net.mkUnboundLocalData ["azoth"];
  unboundMeshA = builtins.elem ''"azoth.internal.mutantmell.net. A 10.1.20.50"'' unboundMesh;
  unboundMeshAShort = builtins.elem ''"azoth.internal. A 10.1.20.50"'' unboundMesh;
  unboundMeshNoAAAA = builtins.length (builtins.filter (s: contains "AAAA" s) unboundMesh) == 0;

  # Record count: 6 per dual-stack host (A+ALegacy+AAAA × canonical+short), 2 per mesh host (A × canonical+short)
  unboundDualStackCount = assertEq "unboundBasic length" (builtins.length unboundBasic) 12;
  unboundMeshCount = assertEq "unboundMesh length" (builtins.length unboundMesh) 2;

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
      host = "legram";
      proto = "tcp";
      port = 443;
      comment = "ACME certs from legram";
    }
  ];
  hostV4 = builtins.elem ''ip daddr ${net.hosts.legram.ipv4} tcp dport 443 accept  comment "ACME certs from legram"'' hostRules;
  hostV4Legacy = builtins.elem ''ip daddr ${net.hosts.legram.ipv4Legacy} tcp dport 443 accept  comment "ACME certs from legram"'' hostRules;
  hostV6 = builtins.elem ''ip6 daddr ${net.hosts.legram.ipv6} tcp dport 443 accept  comment "ACME certs from legram"'' hostRules;
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
      host = "heimdallr";
      proto = "tcp";
      port = [80 443];
    }
  ];
  multiPortV4 = builtins.elem "ip daddr ${net.hosts.heimdallr.ipv4} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortV4Legacy = builtins.elem "ip daddr ${net.hosts.heimdallr.ipv4Legacy} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortV6 = builtins.elem "ip6 daddr ${net.hosts.heimdallr.ipv6} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortCount = assertEq "multiPortRules length" (builtins.length multiPortRules) 3;

  allTests = {
    # mkExtraHosts
    "mkExtraHosts produces primary IPv4 for roer" = extraHostsRoerCanonical;
    "mkExtraHosts produces legacy IPv4 for roer" = extraHostsRoerLegacy;
    "mkExtraHosts produces IPv6 for roer" = extraHostsRoerV6Canonical;
    "mkExtraHosts produces primary IPv4 for legram" = extraHostsLegramCanonical;
    "mkExtraHosts produces legacy IPv4 for legram" = extraHostsLegramLegacy;
    "mkExtraHosts produces IPv6 for legram" = extraHostsLegramV6Canonical;
    "mkExtraHosts produces IPv4 for mesh host" = extraHostsMeshV4;
    "mkExtraHosts skips IPv6 for mesh host" = extraHostsMeshNoV6;
    "mkExtraHosts skips legacy for mesh host" = extraHostsMeshNoLegacy;

    # mkUnboundLocalData — canonical entries
    "mkUnboundLocalData produces canonical A for phantasma" = unboundPlantasmaA;
    "mkUnboundLocalData produces canonical A legacy for phantasma" = unboundPlantasmaALegacy;
    "mkUnboundLocalData produces canonical AAAA for phantasma" = unboundPlantasmaAAAA;
    "mkUnboundLocalData produces canonical A for ordis" = unboundOrdisA;
    "mkUnboundLocalData produces canonical A legacy for ordis" = unboundOrdisALegacy;
    "mkUnboundLocalData produces canonical AAAA for ordis" = unboundOrdisAAAA;
    # mkUnboundLocalData — short alias entries
    "mkUnboundLocalData produces short A for phantasma" = unboundPlantasmaAShort;
    "mkUnboundLocalData produces short A legacy for phantasma" = unboundPlantasmaAShortLegacy;
    "mkUnboundLocalData produces short AAAA for phantasma" = unboundPlantasmaAAAAShort;
    "mkUnboundLocalData produces short A for ordis" = unboundOrdisAShort;
    "mkUnboundLocalData produces short A legacy for ordis" = unboundOrdisAShortLegacy;
    "mkUnboundLocalData produces short AAAA for ordis" = unboundOrdisAAAAShort;
    # mkUnboundLocalData — mesh + counts
    "mkUnboundLocalData produces canonical A for mesh host" = unboundMeshA;
    "mkUnboundLocalData produces short A for mesh host" = unboundMeshAShort;
    "mkUnboundLocalData skips AAAA for mesh host" = unboundMeshNoAAAA;
    "mkUnboundLocalData dual-stack host produces 12 records" = unboundDualStackCount;
    "mkUnboundLocalData mesh host produces 2 records" = unboundMeshCount;

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
