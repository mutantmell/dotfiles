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

  mgmtSubnet4 = assertEq "management subnet4" mgmt.subnet4 "10.97.11.0/24";
  mgmtSubnet6 = assertEq "management subnet6" mgmt.subnet6 "fdc6:55f2:0a5e:b::/64";
  mgmtGateway4 = assertEq "management gateway4" mgmt.gateway4 "10.97.11.1";
  mgmtGateway6 = assertEq "management gateway6" mgmt.gateway6 "fdc6:55f2:0a5e:b::1";

  dmzSubnet4 = assertEq "dmz subnet4" dmz.subnet4 "10.97.100.0/24";
  dmzSubnet6 = assertEq "dmz subnet6" dmz.subnet6 "fdc6:55f2:0a5e:64::/64";
  dmzGateway4 = assertEq "dmz gateway4" dmz.gateway4 "10.97.100.1";

  trustedSubnet4 = assertEq "trusted subnet4" trusted.subnet4 "10.97.20.0/24";
  trustedSubnet6 = assertEq "trusted subnet6" trusted.subnet6 "fdc6:55f2:0a5e:14::/64";

  # --- mkHost: address derivation ---

  testHost = net.mkHost "management" 11 6;
  mkHostIpv4 = assertEq "mkHost ipv4" testHost.ipv4 "10.97.11.6";
  mkHostIpv6 = assertEq "mkHost ipv6" testHost.ipv6 "fdc6:55f2:0a5e:b::6";
  mkHostCidr4 = assertEq "mkHost cidr4" testHost.cidr4 "10.97.11.6/24";
  mkHostCidr6 = assertEq "mkHost cidr6" testHost.cidr6 "fdc6:55f2:0a5e:b::6/64";
  mkHostSubnet4 = assertEq "mkHost subnet4" testHost.subnet4 "10.97.11.0/24";
  mkHostZone = assertEq "mkHost zoneName" testHost.zoneName "management";
  mkHostVlanId = assertEq "mkHost vlanId" testHost.vlanId 11;
  mkHostHostId = assertEq "mkHost hostId" testHost.hostId 6;

  # --- hosts: flattened lookup ---

  hostsHasThebeyond = assertEq "hosts has thebeyond" (net.hosts ? thebeyond) true;
  hostsHasLangport = assertEq "hosts has langport" (net.hosts ? langport) true;
  hostsThebeyondIpv4 = assertEq "thebeyond ipv4" net.hosts.thebeyond.ipv4 "10.97.11.1";
  hostsThebeyondZone = assertEq "thebeyond zone" net.hosts.thebeyond.zoneName "management";
  hostsLangportIpv4 = assertEq "langport ipv4" net.hosts.langport.ipv4 "10.97.100.41";
  hostsLangportZone = assertEq "langport zone" net.hosts.langport.zoneName "dmz";

  # Host in hex-significant VLAN (dmz = 100 = 0x64)
  hostsDmzSubnet = assertEq "dmz host subnet6" net.hosts.langport.subnet6 "fdc6:55f2:0a5e:64::/64";
  # Host with hex hostId (azoth = 50 = 0x32)
  hostsAzothIpv6 = assertEq "azoth ipv6" net.hosts.azoth.ipv6 "fdc6:55f2:0a5e:14::32";

  # --- forHost: structured lookup ---

  forThebeyond = net.forHost "thebeyond";
  forHostReturnsHost = assertEq "forHost host ipv4" forThebeyond.host.ipv4 "10.97.11.1";
  forHostReturnsZone = assertEq "forHost zone gateway4" forThebeyond.zone.gateway4 "10.97.11.1";
  forHostZoneName = assertEq "forHost host zoneName" forThebeyond.host.zoneName "management";
  forHostZoneSubnet = assertEq "forHost zone subnet4" forThebeyond.zone.subnet4 "10.97.11.0/24";

  forLangport = net.forHost "langport";
  forHostDmzHost = assertEq "forHost langport ipv4" forLangport.host.ipv4 "10.97.100.41";
  forHostDmzZone = assertEq "forHost langport zone gateway4" forLangport.zone.gateway4 "10.97.100.1";

  # forHost throws on unknown host
  forHostUnknown =
    !(builtins.tryEval (builtins.seq (net.forHost "nonexistent-host").host.ipv4 true)).success;

  # --- allHostDomains: batch domain lookup ---

  allDomainsHasThebeyond = assertEq "allHostDomains has thebeyond" (net.allHostDomains ? thebeyond) true;
  allDomainsThebeyondCount = assertEq "allHostDomains thebeyond count" (builtins.length net.allHostDomains.thebeyond) 5;
  allDomainsBaselCount = assertEq "allHostDomains basel count" (builtins.length net.allHostDomains.basel) 3;

  allTests = {
    # networks
    "management subnet4" = mgmtSubnet4;
    "management subnet6" = mgmtSubnet6;
    "management gateway4" = mgmtGateway4;
    "management gateway6" = mgmtGateway6;
    "dmz subnet4" = dmzSubnet4;
    "dmz subnet6" = dmzSubnet6;
    "dmz gateway4" = dmzGateway4;
    "trusted subnet4" = trustedSubnet4;
    "trusted subnet6" = trustedSubnet6;

    # mkHost
    "mkHost produces correct ipv4" = mkHostIpv4;
    "mkHost produces correct ipv6" = mkHostIpv6;
    "mkHost produces correct cidr4" = mkHostCidr4;
    "mkHost produces correct cidr6" = mkHostCidr6;
    "mkHost produces correct subnet4" = mkHostSubnet4;
    "mkHost sets zoneName" = mkHostZone;
    "mkHost sets vlanId" = mkHostVlanId;
    "mkHost sets hostId" = mkHostHostId;

    # hosts
    "hosts contains thebeyond" = hostsHasThebeyond;
    "hosts contains langport" = hostsHasLangport;
    "thebeyond has correct ipv4" = hostsThebeyondIpv4;
    "thebeyond is in management zone" = hostsThebeyondZone;
    "langport has correct ipv4" = hostsLangportIpv4;
    "langport is in dmz zone" = hostsLangportZone;
    "dmz host has hex vlan in subnet6" = hostsDmzSubnet;
    "azoth has hex hostId in ipv6" = hostsAzothIpv6;

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
