# Network registry unit tests
#
# Pure Nix evaluation tests for the network data layer:
# forHost, networks, mkHost, hosts, allHostDomains.
#
# Run: nix-instantiate --eval --strict tests/lib/network-registry.nix
# Or:  nix build .#checks.x86_64-linux.network-registry
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  net = import ../../lib/common/data/network.nix {inherit lib;};

  assertEq = name: a: b:
    if a == b
    then true
    else builtins.trace "FAIL: ${name}\n  expected: ${builtins.toJSON b}\n  got:      ${builtins.toJSON a}" false;

  # --- networks: derived subnets and gateways ---

  mgmt = net.networks.management;
  inherit (net.networks) dmz;
  inherit (net.networks) trusted;

  # management is bt8gw-owned (group 1, vlanId 11): prefix = "10.97.11", ULA = "100b"
  mgmtSubnet4 = assertEq "management subnet4" mgmt.subnet4 "10.97.11.0/24";
  mgmtSubnet6 = assertEq "management subnet6" mgmt.subnet6 "fdc6:55f2:0a5e:100b::/64";
  mgmtGateway4 = assertEq "management gateway4" mgmt.gateway4 "10.97.11.1";
  mgmtGateway6 = assertEq "management gateway6" mgmt.gateway6 "fdc6:55f2:0a5e:100b::1";

  # dmz is thebeyond-owned (group 0, vlanId 100): prefix = "10.91.100", ULA = "0064"
  dmzSubnet4 = assertEq "dmz subnet4" dmz.subnet4 "10.91.100.0/24";
  dmzSubnet6 = assertEq "dmz subnet6" dmz.subnet6 "fdc6:55f2:0a5e:0064::/64";
  dmzGateway4 = assertEq "dmz gateway4" dmz.gateway4 "10.91.100.1";

  # trusted is bt8gw-owned (group 1, vlanId 20): prefix = "10.97.20", ULA = "1014"
  trustedSubnet4 = assertEq "trusted subnet4" trusted.subnet4 "10.97.20.0/24";
  trustedSubnet6 = assertEq "trusted subnet6" trusted.subnet6 "fdc6:55f2:0a5e:1014::/64";

  # network is thebeyond-owned (group 0, vlanId 10): prefix = "10.91.10", ULA = "000a"
  networkGateway4 = assertEq "network gateway4" net.networks.network.gateway4 "10.91.10.1";
  networkSubnet4 = assertEq "network subnet4" net.networks.network.subnet4 "10.91.10.0/24";

  # prefixLength defaults to 24
  mgmtPrefixLen = assertEq "management prefixLength4" mgmt.prefixLength4 24;
  dmzPrefixLen = assertEq "dmz prefixLength4" dmz.prefixLength4 24;

  # --- mkHost: address derivation ---

  # management zone: bt8gw group 1, vlanId 11 → prefix4 "10.97.11", prefix6 "fdc6:55f2:0a5e:100b"
  testHost = net.mkHost "management" 11 6;
  mkHostIpv4 = assertEq "mkHost ipv4" testHost.ipv4 "10.97.11.6";
  mkHostIpv6 = assertEq "mkHost ipv6" testHost.ipv6 "fdc6:55f2:0a5e:100b::6";
  mkHostCidr4 = assertEq "mkHost cidr4" testHost.cidr4 "10.97.11.6/24";
  mkHostCidr6 = assertEq "mkHost cidr6" testHost.cidr6 "fdc6:55f2:0a5e:100b::6/64";
  mkHostSubnet4 = assertEq "mkHost subnet4" testHost.subnet4 "10.97.11.0/24";
  mkHostZone = assertEq "mkHost zoneName" testHost.zoneName "management";
  mkHostVlanId = assertEq "mkHost vlanId" testHost.vlanId 11;
  mkHostHostId = assertEq "mkHost hostId" testHost.hostId 6;

  # --- hosts: flattened lookup ---

  # thebeyond is now in network.hosts = 1 → IP 10.91.10.1
  hostsHasThebeyond = assertEq "hosts has thebeyond" (net.hosts ? thebeyond) true;
  hostsHasLangport = assertEq "hosts has langport" (net.hosts ? langport) true;
  hostsThebeyondIpv4 = assertEq "thebeyond ipv4" net.hosts.thebeyond.ipv4 "10.91.10.1";
  hostsThebeyondZone = assertEq "thebeyond zone" net.hosts.thebeyond.zoneName "network";
  hostsLangportIpv4 = assertEq "langport ipv4" net.hosts.langport.ipv4 "10.91.100.41";
  hostsLangportZone = assertEq "langport zone" net.hosts.langport.zoneName "dmz";

  # phantasma moved to network.hosts = 10 → IP 10.91.10.10
  hostsPhantasmaIpv4 = assertEq "phantasma ipv4" net.hosts.phantasma.ipv4 "10.91.10.10";
  hostsPhantasmaZone = assertEq "phantasma zone" net.hosts.phantasma.zoneName "network";

  # bt8bridge added to network.hosts = 4 → IP 10.91.10.4
  hostsBt8bridgeIpv4 = assertEq "bt8bridge ipv4" net.hosts.bt8bridge.ipv4 "10.91.10.4";

  # dmz host subnet6 uses thebeyond group 0 + vlanId 100 = "0064"
  hostsDmzSubnet = assertEq "dmz host subnet6" net.hosts.langport.subnet6 "fdc6:55f2:0a5e:0064::/64";

  # azoth in trusted (bt8gw group 1, vlanId 20 = "1014"), hostId 50 = "32"
  hostsAzothIpv6 = assertEq "azoth ipv6" net.hosts.azoth.ipv6 "fdc6:55f2:0a5e:1014::32";

  # E8450 devices have been dropped
  hostsNoMerkabah = assertEq "merkabah removed" (net.hosts ? merkabah) false;
  hostsNoBobcat = assertEq "bobcat removed" (net.hosts ? bobcat) false;

  # --- forHost: structured lookup ---

  forThebeyond = net.forHost "thebeyond";
  forHostReturnsHost = assertEq "forHost host ipv4" forThebeyond.host.ipv4 "10.91.10.1";
  forHostReturnsZone = assertEq "forHost zone gateway4" forThebeyond.zone.gateway4 "10.91.10.1";
  forHostZoneName = assertEq "forHost host zoneName" forThebeyond.host.zoneName "network";
  forHostZoneSubnet = assertEq "forHost zone subnet4" forThebeyond.zone.subnet4 "10.91.10.0/24";

  forLangport = net.forHost "langport";
  forHostDmzHost = assertEq "forHost langport ipv4" forLangport.host.ipv4 "10.91.100.41";
  forHostDmzZone = assertEq "forHost langport zone gateway4" forLangport.zone.gateway4 "10.91.100.1";

  # forHost throws on unknown host
  forHostUnknown =
    !(builtins.tryEval (builtins.seq (net.forHost "nonexistent-host").host.ipv4 true)).success;

  # --- allHostDomains: batch domain lookup ---

  allDomainsHasThebeyond = assertEq "allHostDomains has thebeyond" (net.allHostDomains ? thebeyond) true;
  allDomainsThebeyondCount = assertEq "allHostDomains thebeyond count" (builtins.length net.allHostDomains.thebeyond) 5;
  allDomainsBaselCount = assertEq "allHostDomains basel count" (builtins.length net.allHostDomains.basel) 3;

  # --- mkDualStackRules: dual-stack firewall rule expansion ---

  tharbadHost = net.hosts.tharbad;
  messeldamHost = net.hosts.messeldam;

  dualBoth = net.mkDualStackRules {
    saddr = tharbadHost;
    daddr = messeldamHost;
    tcp.dport = 443;
    verdict = "accept";
    comment = "test rule";
  };
  dualBothLen = assertEq "mkDualStackRules produces 2 rules" (builtins.length dualBoth) 2;
  dualBothV4Saddr =
    assertEq "mkDualStackRules v4 saddr"
    (builtins.elemAt dualBoth 0).ip.saddr
    tharbadHost.ipv4;
  dualBothV4Daddr =
    assertEq "mkDualStackRules v4 daddr"
    (builtins.elemAt dualBoth 0).ip.daddr
    messeldamHost.ipv4;
  dualBothV6Saddr =
    assertEq "mkDualStackRules v6 saddr"
    (builtins.elemAt dualBoth 1).ip6.saddr
    tharbadHost.ipv6;
  dualBothV6Daddr =
    assertEq "mkDualStackRules v6 daddr"
    (builtins.elemAt dualBoth 1).ip6.daddr
    messeldamHost.ipv6;
  dualBothV4Comment =
    assertEq "mkDualStackRules v4 comment"
    (builtins.elemAt dualBoth 0).comment "test rule";
  dualBothV6Comment =
    assertEq "mkDualStackRules v6 comment"
    (builtins.elemAt dualBoth 1).comment "test rule (v6)";
  dualBothVerdict =
    assertEq "mkDualStackRules preserves verdict"
    (builtins.elemAt dualBoth 0).verdict "accept";
  dualBothPort =
    assertEq "mkDualStackRules preserves port"
    (builtins.elemAt dualBoth 0).tcp.dport
    443;

  dualDstOnly = net.mkDualStackRules {
    daddr = messeldamHost;
    tcp.dport = 80;
    verdict = "accept";
  };
  dualDstOnlyNoSrc =
    assertEq "mkDualStackRules dst-only has no saddr in ip"
    ((builtins.elemAt dualDstOnly 0).ip ? saddr)
    false;
  dualDstOnlyHasDaddr =
    assertEq "mkDualStackRules dst-only has ip.daddr"
    (builtins.elemAt dualDstOnly 0).ip.daddr
    messeldamHost.ipv4;
  dualDstOnlyNoComment =
    assertEq "mkDualStackRules no comment when absent"
    ((builtins.elemAt dualDstOnly 0) ? comment)
    false;
  dualDstOnlyNoCommentV6 =
    assertEq "mkDualStackRules no comment v6 when absent"
    ((builtins.elemAt dualDstOnly 1) ? comment)
    false;

  dualSrcOnly = net.mkDualStackRules {
    saddr = tharbadHost;
    tcp.dport = 9100;
    verdict = "accept";
    comment = "src only";
  };
  dualSrcOnlyV4Saddr =
    assertEq "mkDualStackRules src-only v4 saddr"
    (builtins.elemAt dualSrcOnly 0).ip.saddr
    tharbadHost.ipv4;
  dualSrcOnlyNoDaddr =
    assertEq "mkDualStackRules src-only has no daddr in ip"
    ((builtins.elemAt dualSrcOnly 0).ip ? daddr)
    false;
  dualSrcOnlyV6Saddr =
    assertEq "mkDualStackRules src-only v6 saddr"
    (builtins.elemAt dualSrcOnly 1).ip6.saddr
    tharbadHost.ipv6;

  allTests = {
    # networks
    "management subnet4" = mgmtSubnet4;
    "management subnet6 (bt8gw group 1)" = mgmtSubnet6;
    "management gateway4" = mgmtGateway4;
    "management gateway6 (bt8gw group 1)" = mgmtGateway6;
    "dmz subnet4 (thebeyond group 0)" = dmzSubnet4;
    "dmz subnet6 (thebeyond group 0)" = dmzSubnet6;
    "dmz gateway4 (thebeyond group 0)" = dmzGateway4;
    "trusted subnet4" = trustedSubnet4;
    "trusted subnet6 (bt8gw group 1)" = trustedSubnet6;
    "network gateway4 (thebeyond group 0)" = networkGateway4;
    "network subnet4" = networkSubnet4;
    "management prefixLength4 defaults to 24" = mgmtPrefixLen;
    "dmz prefixLength4 defaults to 24" = dmzPrefixLen;

    # mkHost
    "mkHost produces correct ipv4" = mkHostIpv4;
    "mkHost produces correct ipv6 (bt8gw group 1)" = mkHostIpv6;
    "mkHost produces correct cidr4" = mkHostCidr4;
    "mkHost produces correct cidr6 (bt8gw group 1)" = mkHostCidr6;
    "mkHost produces correct subnet4" = mkHostSubnet4;
    "mkHost sets zoneName" = mkHostZone;
    "mkHost sets vlanId" = mkHostVlanId;
    "mkHost sets hostId" = mkHostHostId;

    # hosts
    "hosts contains thebeyond" = hostsHasThebeyond;
    "hosts contains langport" = hostsHasLangport;
    "thebeyond has correct ipv4 (network zone)" = hostsThebeyondIpv4;
    "thebeyond is in network zone" = hostsThebeyondZone;
    "langport has correct ipv4 (dmz)" = hostsLangportIpv4;
    "langport is in dmz zone" = hostsLangportZone;
    "phantasma moved to network zone" = hostsPhantasmaIpv4;
    "phantasma is in network zone" = hostsPhantasmaZone;
    "bt8bridge added to network zone" = hostsBt8bridgeIpv4;
    "dmz host has fixed-width hex vlan in subnet6" = hostsDmzSubnet;
    "azoth has bt8gw group 1 ULA prefix" = hostsAzothIpv6;
    "merkabah removed from registry" = hostsNoMerkabah;
    "bobcat removed from registry" = hostsNoBobcat;

    # forHost
    "forHost returns host record" = forHostReturnsHost;
    "forHost returns zone record" = forHostReturnsZone;
    "forHost host has correct zoneName" = forHostZoneName;
    "forHost zone has correct subnet4" = forHostZoneSubnet;
    "forHost works for dmz host" = forHostDmzHost;
    "forHost returns dmz zone" = forHostDmzZone;
    "forHost throws on unknown host" = forHostUnknown;

    # allHostDomains
    "allHostDomains contains thebeyond" = allDomainsHasThebeyond;
    "allHostDomains thebeyond has 5 domains" = allDomainsThebeyondCount;
    "allHostDomains basel has 3 domains" = allDomainsBaselCount;

    # mkDualStackRules
    "mkDualStackRules produces 2 rules" = dualBothLen;
    "mkDualStackRules v4 saddr" = dualBothV4Saddr;
    "mkDualStackRules v4 daddr" = dualBothV4Daddr;
    "mkDualStackRules v6 saddr" = dualBothV6Saddr;
    "mkDualStackRules v6 daddr" = dualBothV6Daddr;
    "mkDualStackRules v4 comment" = dualBothV4Comment;
    "mkDualStackRules v6 comment" = dualBothV6Comment;
    "mkDualStackRules preserves verdict" = dualBothVerdict;
    "mkDualStackRules preserves port" = dualBothPort;
    "mkDualStackRules dst-only has no saddr" = dualDstOnlyNoSrc;
    "mkDualStackRules dst-only has daddr" = dualDstOnlyHasDaddr;
    "mkDualStackRules no comment when absent" = dualDstOnlyNoComment;
    "mkDualStackRules no comment v6 when absent" = dualDstOnlyNoCommentV6;
    "mkDualStackRules src-only v4 saddr" = dualSrcOnlyV4Saddr;
    "mkDualStackRules src-only has no daddr" = dualSrcOnlyNoDaddr;
    "mkDualStackRules src-only v6 saddr" = dualSrcOnlyV6Saddr;
  };

  failures = lib.filterAttrs (_: v: !v) allTests;
  failCount = builtins.length (builtins.attrNames failures);
  passCount = builtins.length (builtins.attrNames allTests) - failCount;
in
  if failCount > 0
  then
    builtins.throw "network-registry: ${toString failCount} test(s) failed:\n${
      lib.concatMapStringsSep "\n" (name: "  FAIL: ${name}") (builtins.attrNames failures)
    }"
  else
    pkgs.runCommand "network-registry-tests" {} ''
      echo "network-registry: ${toString passCount}/${toString passCount} tests passed"
      echo passed > $out
    ''
