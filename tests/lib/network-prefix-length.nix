# Network prefix-length unit tests
#
# Tests for ulaSubnetHex encoding, prefix-length-aware host range math,
# and per-gateway address derivation in the network registry.
#
# Run: nix-instantiate --eval --strict tests/lib/network-prefix-length.nix
# Or:  nix build .#checks.x86_64-linux.network-prefix-length
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  net = import ../../lib/common/data/network.nix {inherit lib;};

  assertEq = name: a: b:
    if a == b
    then true
    else builtins.trace "FAIL: ${name}\n  expected: ${builtins.toJSON b}\n  got:      ${builtins.toJSON a}" false;

  # Mirror the hostRangeCheck max-ID formula from network.nix
  maxHostId = prefixLength: let
    hostBits = 32 - prefixLength;
  in
    (builtins.foldl' (a: _: a * 2) 1 (lib.range 1 hostBits)) - 2;

  # --- ulaSubnetHex: 4-digit hex encoding of gateway-group + VLAN ---

  # group 0 (thebeyond): vlan 10 → 0*4096+10=10 = 0xa → "000a"
  hexGroup0Vlan10 = assertEq "ulaSubnetHex group0 vlan10" (net.ulaSubnetHex 0 10) "000a";
  # group 0 (thebeyond): vlan 100 → 0*4096+100=100 = 0x64 → "0064"
  hexGroup0Vlan100 = assertEq "ulaSubnetHex group0 vlan100" (net.ulaSubnetHex 0 100) "0064";
  # group 1 (bt8gw): vlan 11 → 1*4096+11=4107 = 0x100b → "100b"
  hexGroup1Vlan11 = assertEq "ulaSubnetHex group1 vlan11" (net.ulaSubnetHex 1 11) "100b";
  # group 1 (bt8gw): vlan 20 → 1*4096+20=4116 = 0x1014 → "1014"
  hexGroup1Vlan20 = assertEq "ulaSubnetHex group1 vlan20" (net.ulaSubnetHex 1 20) "1014";
  # group 1 (bt8gw): vlan 21 → 1*4096+21=4117 = 0x1015 → "1015"
  hexGroup1Vlan21 = assertEq "ulaSubnetHex group1 vlan21" (net.ulaSubnetHex 1 21) "1015";
  # group 1 (bt8gw): vlan 30 → 1*4096+30=4126 = 0x101e → "101e"
  hexGroup1Vlan30 = assertEq "ulaSubnetHex group1 vlan30" (net.ulaSubnetHex 1 30) "101e";
  # zero-padding: group 0, vlan 1 → 1 = 0x1 → "0001"
  hexZeroPad = assertEq "ulaSubnetHex zero-pads to 4 digits" (net.ulaSubnetHex 0 1) "0001";
  # always 4 chars
  hexLen = assertEq "ulaSubnetHex output length" (builtins.stringLength (net.ulaSubnetHex 1 100)) 4;

  # --- maxHostId: prefix-length-aware host range formula ---

  # /24 → 2^8 - 2 = 254 (standard LAN)
  maxId24 = assertEq "maxHostId /24 = 254" (maxHostId 24) 254;
  # /25 → 2^7 - 2 = 126
  maxId25 = assertEq "maxHostId /25 = 126" (maxHostId 25) 126;
  # /28 → 2^4 - 2 = 14
  maxId28 = assertEq "maxHostId /28 = 14" (maxHostId 28) 14;
  # /29 → 2^3 - 2 = 6
  maxId29 = assertEq "maxHostId /29 = 6" (maxHostId 29) 6;
  # /30 → 2^2 - 2 = 2 (point-to-point, only host IDs 1 and 2 valid)
  maxId30 = assertEq "maxHostId /30 = 2" (maxHostId 30) 2;

  # --- mkHost: prefix-length reflected in CIDR output ---

  # network zone: thebeyond group 0, vlanId 10, /24 → cidr4 uses /24
  hostPhantasma = net.mkHost "network" 10 10;
  phantasmaCidr4 = assertEq "mkHost network zone cidr4 uses /24" hostPhantasma.cidr4 "10.91.10.10/24";
  phantasmaSubnet4 = assertEq "mkHost network zone subnet4 uses /24" hostPhantasma.subnet4 "10.91.10.0/24";

  # High host ID within /24 range (max 254)
  hostHigh = net.mkHost "management" 11 200;
  hostHighIpv4 = assertEq "mkHost high host ID ipv4" hostHigh.ipv4 "10.97.11.200";
  hostHighCidr4 = assertEq "mkHost high host ID cidr4" hostHigh.cidr4 "10.97.11.200/24";

  # --- gateways table ---

  thebeyondGroup = assertEq "gateways.thebeyond.ulaGroup" net.gateways.thebeyond.ulaGroup 0;
  bt8gwGroup = assertEq "gateways.bt8gw.ulaGroup" net.gateways.bt8gw.ulaGroup 1;
  thebeyondPrefix4 = assertEq "gateways.thebeyond.prefix4" net.gateways.thebeyond.prefix4 "10.91";
  bt8gwPrefix4 = assertEq "gateways.bt8gw.prefix4" net.gateways.bt8gw.prefix4 "10.97";

  allTests = {
    # ulaSubnetHex
    "ulaSubnetHex group 0 vlan 10 → 000a" = hexGroup0Vlan10;
    "ulaSubnetHex group 0 vlan 100 → 0064" = hexGroup0Vlan100;
    "ulaSubnetHex group 1 vlan 11 → 100b" = hexGroup1Vlan11;
    "ulaSubnetHex group 1 vlan 20 → 1014" = hexGroup1Vlan20;
    "ulaSubnetHex group 1 vlan 21 → 1015" = hexGroup1Vlan21;
    "ulaSubnetHex group 1 vlan 30 → 101e" = hexGroup1Vlan30;
    "ulaSubnetHex zero-pads to 4 digits" = hexZeroPad;
    "ulaSubnetHex always produces 4 chars" = hexLen;

    # maxHostId
    "maxHostId /24 = 254" = maxId24;
    "maxHostId /25 = 126" = maxId25;
    "maxHostId /28 = 14" = maxId28;
    "maxHostId /29 = 6" = maxId29;
    "maxHostId /30 = 2" = maxId30;

    # mkHost
    "mkHost network zone cidr4 uses /24" = phantasmaCidr4;
    "mkHost network zone subnet4 uses /24" = phantasmaSubnet4;
    "mkHost handles high host ID (200) in /24" = hostHighIpv4;
    "mkHost high host ID has correct cidr4" = hostHighCidr4;

    # gateways table
    "gateways.thebeyond has ulaGroup 0" = thebeyondGroup;
    "gateways.bt8gw has ulaGroup 1" = bt8gwGroup;
    "gateways.thebeyond has prefix4 10.91" = thebeyondPrefix4;
    "gateways.bt8gw has prefix4 10.97" = bt8gwPrefix4;
  };

  failures = lib.filterAttrs (_: v: !v) allTests;
  failCount = builtins.length (builtins.attrNames failures);
  passCount = builtins.length (builtins.attrNames allTests) - failCount;
in
  if failCount > 0
  then
    builtins.throw "network-prefix-length: ${toString failCount} test(s) failed:\n${
      lib.concatMapStringsSep "\n" (name: "  FAIL: ${name}") (builtins.attrNames failures)
    }"
  else
    pkgs.runCommand "network-prefix-length-tests" {} ''
      echo "network-prefix-length: ${toString passCount}/${toString passCount} tests passed"
      echo passed > $out
    ''
