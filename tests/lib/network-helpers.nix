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

  extraHostsBasic = net.mkExtraHosts [ "mimir" "tyr" ];
  extraHostsMimir = contains "10.0.11.3 mimir.local" extraHostsBasic;
  extraHostsMimirV6 = contains "fdc6:55f2:0a5e:b::3 mimir.local" extraHostsBasic;
  extraHostsTyr = contains "10.0.11.4 tyr.local" extraHostsBasic;
  extraHostsTyrV6 = contains "fdc6:55f2:0a5e:b::4 tyr.local" extraHostsBasic;

  # Mesh hosts have no IPv6 — should produce only IPv4 line
  extraHostsMesh = net.mkExtraHosts [ "nidavellir" ];
  extraHostsMeshV4 = contains "10.1.20.50 nidavellir.local" extraHostsMesh;
  extraHostsMeshNoV6 = !(contains "AAAA" extraHostsMesh || contains "fdc6" extraHostsMesh);

  # --- mkUnboundLocalData tests ---

  unboundBasic = net.mkUnboundLocalData [ "alfheim" "surtr" ];
  unboundAlfheimA = builtins.elem ''"alfheim.local. A ${net.hosts.alfheim.ipv4}"'' unboundBasic;
  unboundAlfheimAAAA = builtins.elem ''"alfheim.local. AAAA ${net.hosts.alfheim.ipv6}"'' unboundBasic;
  unboundSurtrA = builtins.elem ''"surtr.local. A ${net.hosts.surtr.ipv4}"'' unboundBasic;
  unboundSurtrAAAA = builtins.elem ''"surtr.local. AAAA ${net.hosts.surtr.ipv6}"'' unboundBasic;

  # Mesh hosts: A record only, no AAAA
  unboundMesh = net.mkUnboundLocalData [ "nidavellir" ];
  unboundMeshA = builtins.elem ''"nidavellir.local. A 10.1.20.50"'' unboundMesh;
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
    { host = "tyr"; proto = "tcp"; port = 443; comment = "ACME certs from tyr"; }
  ];
  hostV4 = builtins.elem ''ip daddr ${net.hosts.tyr.ipv4} tcp dport 443 accept  comment "ACME certs from tyr"'' hostRules;
  hostV6 = builtins.elem ''ip6 daddr ${net.hosts.tyr.ipv6} tcp dport 443 accept  comment "ACME certs from tyr"'' hostRules;

  # Host rule for mesh host (no IPv6) produces v4 only
  meshRules = net.mkDualEgressRules mgmtZone [
    { host = "nidavellir"; proto = "tcp"; port = 80; }
  ];
  meshV4Only = assertEq "meshRules length" (builtins.length meshRules) 1;
  meshV4Content = builtins.elem "ip daddr 10.1.20.50 tcp dport 80 accept" meshRules;

  # Multi-port rule
  multiPortRules = net.mkDualEgressRules dmzZone [
    { host = "bragi"; proto = "tcp"; port = [ 80 443 ]; }
  ];
  multiPortV4 = builtins.elem "ip daddr ${net.hosts.bragi.ipv4} tcp dport { 80, 443 } accept" multiPortRules;
  multiPortV6 = builtins.elem "ip6 daddr ${net.hosts.bragi.ipv6} tcp dport { 80, 443 } accept" multiPortRules;

  allTests = {
    # mkExtraHosts
    "mkExtraHosts produces IPv4 for mimir" = extraHostsMimir;
    "mkExtraHosts produces IPv6 for mimir" = extraHostsMimirV6;
    "mkExtraHosts produces IPv4 for tyr" = extraHostsTyr;
    "mkExtraHosts produces IPv6 for tyr" = extraHostsTyrV6;
    "mkExtraHosts produces IPv4 for mesh host" = extraHostsMeshV4;
    "mkExtraHosts skips IPv6 for mesh host" = extraHostsMeshNoV6;

    # mkUnboundLocalData
    "mkUnboundLocalData produces A for alfheim" = unboundAlfheimA;
    "mkUnboundLocalData produces AAAA for alfheim" = unboundAlfheimAAAA;
    "mkUnboundLocalData produces A for surtr" = unboundSurtrA;
    "mkUnboundLocalData produces AAAA for surtr" = unboundSurtrAAAA;
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
