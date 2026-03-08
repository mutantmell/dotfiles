# DHCP config unit tests for router6
#
# Pure Nix evaluation tests verifying:
# - systemd-networkd config for DHCP WAN interfaces (no DefaultRouteOnDevice)
# - systemd-networkd config for static LAN interfaces
# - Kea DHCP4 subnet generation
#
# Run: nix-instantiate --eval --strict tests/lib/router6-dhcp-config.nix
# Or:  nix build .#checks.x86_64-linux.router6-dhcp-config
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  # Helper to evaluate a router6 config and extract systemd-networkd networks
  evalConfig = router6Config: let
    eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules = [
        ../../modules/router6
        {
          boot.loader.grub.device = "nodev";
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "25.11";
          router6 = {enable = true;} // router6Config;
        }
      ];
    };
  in
    eval.config;

  assertEq = name: a: b:
    if a == b
    then true
    else throw "FAIL: ${name}\n  Expected: ${builtins.toJSON b}\n  Got:      ${builtins.toJSON a}";

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  assertFalse = name: v:
    if !v
    then true
    else throw "FAIL: ${name}";

  assertHasAttr = name: attr: set:
    if builtins.hasAttr attr set
    then true
    else throw "FAIL: ${name} — missing attribute '${attr}'";

  assertNoAttr = name: attr: set:
    if !(builtins.hasAttr attr set)
    then true
    else throw "FAIL: ${name} — unexpected attribute '${attr}' = ${builtins.toJSON set.${attr}}";

  # ========================================================================
  # Test config: DHCP WAN + static LAN with DHCP server
  # ========================================================================
  dhcpWanConfig = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    dns.useDHCPFallback = false;
    dns.localDomain = "test.local";
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["trusted" "external"];
        inputRules = [{verdict = "accept";}];
      };
    };
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
          defaultRoute = true;
        };
      };
      lan = {
        hardwareName = "eth1";
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          subnetId = 10;
          dhcp.enable = true;
          dhcp6 = {
            enable = true;
            dnsAddress = "fdc6:55f2:a5e:a::1";
          };
        };
      };
    };
  };

  # ========================================================================
  # Test config: Static WAN (for comparison — should NOT have DHCP)
  # ========================================================================
  staticWanConfig = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    dns.useDHCPFallback = false;
    dns.localDomain = "test.local";
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["trusted" "external"];
        inputRules = [{verdict = "accept";}];
      };
    };
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "static";
          addresses = ["203.0.113.1/24"];
          gateway = "203.0.113.254";
          zone = "external";
          nat.enable = true;
        };
      };
      lan = {
        hardwareName = "eth1";
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
        };
      };
    };
  };

  # ========================================================================
  # Evaluate configs
  # ========================================================================
  dhcpEval = evalConfig dhcpWanConfig;
  staticEval = evalConfig staticWanConfig;

  dhcpNetworks = dhcpEval.systemd.network.networks;
  staticNetworks = staticEval.systemd.network.networks;

  dhcpWanNetwork = dhcpNetworks."10-wan";
  dhcpLanNetwork = dhcpNetworks."10-lan";
  staticWanNetwork = staticNetworks."10-wan";

  # Kea DHCP4 config
  dhcpKeaSettings = dhcpEval.services.kea.dhcp4.settings;
  staticKeaSettings = staticEval.services.kea.dhcp4.settings;

  # ========================================================================
  # Tests
  # ========================================================================
  tests = [
    # ====================================================================
    # systemd-networkd: DHCP WAN interface
    # ====================================================================

    (assertEq "DHCP WAN: DHCP = yes"
      dhcpWanNetwork.networkConfig.DHCP "yes")

    (assertEq "DHCP WAN: IPv6AcceptRA = true"
      dhcpWanNetwork.networkConfig.IPv6AcceptRA
      true)

    # THE KEY BUG FIX TEST: no DefaultRouteOnDevice on DHCP interfaces
    (assertNoAttr "DHCP WAN: no DefaultRouteOnDevice (bug fix)"
      "DefaultRouteOnDevice"
      dhcpWanNetwork.networkConfig)

    (assertEq "DHCP WAN: LinkLocalAddressing = yes"
      dhcpWanNetwork.networkConfig.LinkLocalAddressing "yes")

    (assertEq "DHCP WAN: RequiredForOnline = routable"
      dhcpWanNetwork.linkConfig.RequiredForOnline "routable")

    (assertEq "DHCP WAN: matchConfig.Name = wan"
      dhcpWanNetwork.matchConfig.Name "wan")

    # ====================================================================
    # systemd-networkd: Static LAN interface
    # ====================================================================

    (assertEq "Static LAN: DHCP = no"
      dhcpLanNetwork.networkConfig.DHCP "no")

    (assertEq "Static LAN: IPv6AcceptRA = false"
      dhcpLanNetwork.networkConfig.IPv6AcceptRA
      false)

    (assertTrue "Static LAN: has IPv6SendRA (dhcp6 enabled)"
      (dhcpLanNetwork.networkConfig.IPv6SendRA or false))

    (assertNoAttr "Static LAN: no DefaultRouteOnDevice"
      "DefaultRouteOnDevice"
      dhcpLanNetwork.networkConfig)

    # ====================================================================
    # systemd-networkd: Static WAN interface (comparison)
    # ====================================================================

    (assertEq "Static WAN: DHCP = no"
      staticWanNetwork.networkConfig.DHCP "no")

    (assertEq "Static WAN: IPv6AcceptRA = false"
      staticWanNetwork.networkConfig.IPv6AcceptRA
      false)

    (assertNoAttr "Static WAN: no DefaultRouteOnDevice"
      "DefaultRouteOnDevice"
      staticWanNetwork.networkConfig)

    (assertEq "Static WAN: Gateway set"
      staticWanNetwork.networkConfig.Gateway "203.0.113.254")

    # ====================================================================
    # Kea DHCP4: DHCP WAN config (LAN has DHCP server)
    # ====================================================================

    (assertTrue "Kea: has subnet entries"
      (builtins.length dhcpKeaSettings.subnet4 > 0))

    (let
      subnet = builtins.head dhcpKeaSettings.subnet4;
    in
      assertEq "Kea: subnet matches LAN CIDR"
      subnet.subnet "10.0.10.0/24")

    (let
      subnet = builtins.head dhcpKeaSettings.subnet4;
      pool = builtins.head subnet.pools;
    in
      assertTrue "Kea: pool is within subnet"
      (lib.hasPrefix "10.0.10." pool.pool))

    (let
      subnet = builtins.head dhcpKeaSettings.subnet4;
      routerOpt = lib.findFirst (o: o.name == "routers") null subnet.option-data;
    in
      assertEq "Kea: routers option = gateway"
      routerOpt.data "10.0.10.1")

    (let
      subnet = builtins.head dhcpKeaSettings.subnet4;
      dnsOpt = lib.findFirst (o: o.name == "domain-name-servers") null subnet.option-data;
    in
      assertEq "Kea: DNS option = gateway"
      dnsOpt.data "10.0.10.1")

    (let
      subnet = builtins.head dhcpKeaSettings.subnet4;
      domainOpt = lib.findFirst (o: o.name == "domain-name") null subnet.option-data;
    in
      assertEq "Kea: domain-name option = localDomain"
      domainOpt.data "test.local")

    # Kea interfaces should include lan (which has dhcp.enable)
    (assertTrue "Kea: interfaces include lan"
      (builtins.elem "lan" dhcpKeaSettings.interfaces-config.interfaces))

    # WAN (dhcp type) should NOT be in Kea interfaces (it's a client, not server)
    (assertFalse "Kea: WAN not in DHCP server interfaces"
      (builtins.elem "wan" dhcpKeaSettings.interfaces-config.interfaces))

    # ====================================================================
    # Kea DHCP4: Static WAN config (also has LAN DHCP server)
    # ====================================================================

    (assertTrue "Kea static: has subnet entries"
      (builtins.length staticKeaSettings.subnet4 > 0))

    (let
      subnet = builtins.head staticKeaSettings.subnet4;
    in
      assertEq "Kea static: subnet matches LAN CIDR"
      subnet.subnet "10.0.10.0/24")
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-dhcp-config" {} ''
      echo "All ${toString (builtins.length tests)} DHCP config tests passed"
      echo "PASS" > $out
    ''
  else throw "DHCP config tests failed"
