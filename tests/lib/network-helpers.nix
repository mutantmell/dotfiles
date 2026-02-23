# Network helper unit tests
#
# Pure Nix evaluation tests for mkExtraHosts, mkUnboundLocalData, mkDualEgressRules.
#
# Run: nix-instantiate --eval --strict tests/lib/network-helpers.nix
# Or:  nix build .#checks.x86_64-linux.network-helpers

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  net = import ../../lib/common/data/network.nix { inherit lib; };

  assertEq = name: a: b:
    if a == b then true
    else builtins.trace "FAIL: ${name}\n  expected: ${builtins.toJSON b}\n  got:      ${builtins.toJSON a}" false;

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  # --- mkExtraHosts tests ---

  extraHostsBasic = net.mkExtraHosts [ "roer" "legram" ];
  extraHostsRoer = contains "10.0.11.3 roer.local" extraHostsBasic;
  extraHostsRoerV6 = contains "fdc6:55f2:0a5e:b::3 roer.local" extraHostsBasic;
  extraHostsLegram = contains "10.0.11.4 legram.local" extraHostsBasic;
  extraHostsLegramV6 = contains "fdc6:55f2:0a5e:b::4 legram.local" extraHostsBasic;

  # Mesh hosts have no IPv6 — should produce only IPv4 line
  extraHostsMesh = net.mkExtraHosts [ "azoth" ];
  extraHostsMeshV4 = contains "10.1.20.50 azoth.local" extraHostsMesh;
  extraHostsMeshNoV6 = !(contains "AAAA" extraHostsMesh || contains "fdc6" extraHostsMesh);

  # --- mkUnboundLocalData tests ---

  unboundBasic = net.mkUnboundLocalData [ "plantasma" "ordis" ];
  unboundPlantasmaA = builtins.elem ''"plantasma.local. A ${net.hosts.plantasma.ipv4}"'' unboundBasic;
  unboundPlantasmaAAAA = builtins.elem ''"plantasma.local. AAAA ${net.hosts.plantasma.ipv6}"'' unboundBasic;
  unboundOrdisA = builtins.elem ''"ordis.local. A ${net.hosts.ordis.ipv4}"'' unboundBasic;
  unboundOrdisAAAA = builtins.elem ''"ordis.local. AAAA ${net.hosts.ordis.ipv6}"'' unboundBasic;

  # Mesh hosts: A record only, no AAAA
  unboundMesh = net.mkUnboundLocalData [ "azoth" ];
  unboundMeshA = builtins.elem ''"azoth.local. A 10.1.20.50"'' unboundMesh;
  unboundMeshNoAAAA = builtins.length (builtins.filter (s: contains "AAAA" s) unboundMesh) == 0;

  # --- mkDualEgressRules tests ---

  mgmtZone = net.networks.management;
  dmzZone = net.networks.dmz;

  # Gateway rule produces v4 + v6
  gatewayRules = net.mkDualEgressRules mgmtZone [
    { gateway = true; proto = "udp"; port = 53; }
  ];
  gatewayV4 = builtins.elem "ip daddr ${mgmtZone.gateway4} udp dport 53 accept" gatewayRules;
  gatewayV6 = builtins.elem "ip6 daddr ${mgmtZone.gateway6} udp dport 53 accept" gatewayRules;

  # Host rule produces v4 + v6 for hosts with IPv6
  hostRules = net.mkDualEgressRules dmzZone [
    { host = "legram"; proto = "tcp"; port = 443; comment = "ACME certs from legram"; }
  ];
  hostV4 = builtins.elem ''ip daddr ${net.hosts.legram.ipv4} tcp dport 443 accept  comment "ACME certs from legram"'' hostRules;
  hostV6 = builtins.elem ''ip6 daddr ${net.hosts.legram.ipv6} tcp dport 443 accept  comment "ACME certs from legram"'' hostRules;

  # Host rule for mesh host (no IPv6) produces v4 only
  meshRules = net.mkDualEgressRules mgmtZone [
    { host = "azoth"; proto = "tcp"; port = 80; }
  ];
  meshV4Only = assertEq "meshRules length" (builtins.length meshRules) 1;
  meshV4Content = builtins.elem "ip daddr 10.1.20.50 tcp dport 80 accept" meshRules;

  # Multi-port rule
  multiPortRules = net.mkDualEgressRules dmzZone [
    { host = "heimdallr"; proto = "tcp"; port = [ 80 443 ]; }
  ];
  multiPortV4 = builtins.elem "ip daddr ${net.hosts.heimdallr.ipv4} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortV6 = builtins.elem "ip6 daddr ${net.hosts.heimdallr.ipv6} tcp dport { 80, 443 } accept" multiPortRules;

  allTests = {
    # mkExtraHosts
    "mkExtraHosts produces IPv4 for roer" = extraHostsRoer;
    "mkExtraHosts produces IPv6 for roer" = extraHostsRoerV6;
    "mkExtraHosts produces IPv4 for legram" = extraHostsLegram;
    "mkExtraHosts produces IPv6 for legram" = extraHostsLegramV6;
    "mkExtraHosts produces IPv4 for mesh host" = extraHostsMeshV4;
    "mkExtraHosts skips IPv6 for mesh host" = extraHostsMeshNoV6;

    # mkUnboundLocalData
    "mkUnboundLocalData produces A for plantasma" = unboundPlantasmaA;
    "mkUnboundLocalData produces AAAA for plantasma" = unboundPlantasmaAAAA;
    "mkUnboundLocalData produces A for ordis" = unboundOrdisA;
    "mkUnboundLocalData produces AAAA for ordis" = unboundOrdisAAAA;
    "mkUnboundLocalData produces A for mesh host" = unboundMeshA;
    "mkUnboundLocalData skips AAAA for mesh host" = unboundMeshNoAAAA;

    # mkDualEgressRules
    "mkDualEgressRules gateway produces v4" = gatewayV4;
    "mkDualEgressRules gateway produces v6" = gatewayV6;
    "mkDualEgressRules host produces v4 with comment" = hostV4;
    "mkDualEgressRules host produces v6 with comment" = hostV6;
    "mkDualEgressRules mesh host produces only v4" = meshV4Only;
    "mkDualEgressRules mesh host v4 content" = meshV4Content;
    "mkDualEgressRules multi-port v4" = multiPortV4;
    "mkDualEgressRules multi-port v6" = multiPortV6;
  };

  failures = lib.filterAttrs (_: v: !v) allTests;
  failCount = builtins.length (builtins.attrNames failures);
  passCount = builtins.length (builtins.attrNames allTests) - failCount;

in
  if failCount > 0 then
    builtins.throw "network-helpers: ${toString failCount} test(s) failed:\n${
      lib.concatMapStringsSep "\n" (name: "  FAIL: ${name}") (builtins.attrNames failures)
    }"
  else
    pkgs.runCommand "network-helpers-tests" {} ''
      echo "network-helpers: ${toString passCount}/${toString passCount} tests passed"
      echo passed > $out
    ''
