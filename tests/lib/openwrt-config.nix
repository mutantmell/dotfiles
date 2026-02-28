# OpenWrt config generation unit tests
#
# Pure Nix evaluation tests for mkDeviceConfig — verifies that device
# declarations produce the expected UCI config structure.
#
# Run: nix-instantiate --eval --strict tests/lib/openwrt-config.nix
# Or:  nix build .#checks.x86_64-linux.openwrt-config

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  openwrt = import ../../lib/openwrt { inherit lib; openwrt-imagebuilder = null; };
  owrtData = import ../../lib/common/data/openwrt.nix { inherit lib; };

  assertEq = name: a: b:
    if a == b then true
    else builtins.trace "FAIL: ${name}\n  expected: ${builtins.toJSON b}\n  got:      ${builtins.toJSON a}" false;

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  # --- Test device declarations ---

  meshDevice = {
    type = "meshAP";
    hostname = "test-mesh";
    profile = "linksys_e8450-ubi";
    hostId = 99;
    heBssColor = 42;
    legacyRates = true;
  };

  switchDevice = {
    type = "switch";
    hostname = "test-switch";
    profile = "netgear_gs108t-v3";
    hostId = 50;
    vlanId = 10;
  };

  simpleAPDevice = {
    type = "simpleAP";
    hostname = "test-simple";
    profile = "tplink_eap615-wall-v1";
    hostId = 30;
    vlanId = 31;
    ssid = "TestNetwork";
  };

  routerDevice = {
    type = "router";
    hostname = "test-router";
    profile = "linksys_e8450-ubi";
    ssid = "TestNetwork";
  };

  meshWithExtra = meshDevice // {
    hostname = "test-mesh-extra";
    extraConfig = {
      network.custom = {
        _type = "interface";
        proto = "static";
        device = "bat0.1040";
      };
    };
  };

  # --- Generate configs ---

  meshConfig = openwrt.mkDeviceConfig { device = meshDevice; inherit owrtData; };
  switchConfig = openwrt.mkDeviceConfig { device = switchDevice; inherit owrtData; };
  simpleAPConfig = openwrt.mkDeviceConfig { device = simpleAPDevice; inherit owrtData; };
  meshExtraConfig = openwrt.mkDeviceConfig { device = meshWithExtra; inherit owrtData; };
  routerConfig = openwrt.mkDeviceConfig { device = routerDevice; inherit owrtData; };

  # --- Render to UCI commands ---

  meshUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs meshConfig);
  switchUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs switchConfig);
  simpleAPUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs simpleAPConfig);
  routerUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs routerConfig);

  # --- Test real device declarations load ---

  realDevices = import ../../hosts/openwrt { inherit lib; };

  # --- Tests ---

  allTests = {
    # Mesh AP config structure
    "meshAP has system config" = meshConfig ? system;
    "meshAP has network config" = meshConfig ? network;
    "meshAP has wireless config" = meshConfig ? wireless;
    "meshAP has dropbear config" = meshConfig ? dropbear;

    "meshAP hostname set" = meshConfig.system.system.hostname == "test-mesh";
    "meshAP timezone defaults to LA" = meshConfig.system.system.timezone == "America/Los_Angeles";
    "meshAP has bat0" = meshConfig.network ? bat0;
    "meshAP bat0 is batadv" = meshConfig.network.bat0.proto == "batadv";
    "meshAP has br-lan bridge" = meshConfig.network ? br_lan;
    "meshAP has mgmt bridge" = meshConfig.network ? br_mgmt;
    "meshAP has admin bridge" = meshConfig.network ? br_admin;
    "meshAP has mesh interface" = meshConfig.wireless ? batmesh;
    "meshAP mesh uses correct ID" = meshConfig.wireless.batmesh.mesh_id == owrtData.meshConfig.meshId;
    "meshAP has he_bss_color" = meshConfig.wireless.radio1.he_bss_color == 42;
    "meshAP has legacy_rates" = meshConfig.wireless.radio0.legacy_rates == true;

    "meshAP lan addresses use HOME VLAN" =
      assertEq "meshAP lan addresses"
        meshConfig.network.lan.ipaddr
        (owrtData.mkAddresses owrtData.meshVlans.HOME.tag 99);

    "meshAP mgmt addresses use MGMT VLAN" =
      assertEq "meshAP mgmt addresses"
        meshConfig.network.mgmt.ipaddr
        (owrtData.mkAddresses owrtData.meshVlans.MGMT.tag 99);

    "meshAP gateway uses HOME VLAN" =
      assertEq "meshAP gateway"
        meshConfig.network.lan.gateway
        (owrtData.mkGateway owrtData.meshVlans.HOME.tag);

    "meshAP dropbear disables password auth" =
      meshConfig.dropbear.main.PasswordAuth == false;

    # Mesh AP with extra config
    "meshAP extra config merged" = meshExtraConfig.network ? custom;
    "meshAP extra config device" = meshExtraConfig.network.custom.device == "bat0.1040";

    # Switch config structure
    "switch has system config" = switchConfig ? system;
    "switch has network config" = switchConfig ? network;
    "switch has no wireless" = !(switchConfig ? wireless);
    "switch has dropbear config" = switchConfig ? dropbear;

    "switch hostname set" = switchConfig.system.system.hostname == "test-switch";
    "switch has bridge device" = switchConfig.network ? switch;
    "switch bridge is bridge type" = switchConfig.network.switch.type == "bridge";

    "switch lan addresses use correct VLAN" =
      assertEq "switch lan addresses"
        switchConfig.network.lan.ipaddr
        (owrtData.mkAddresses 10 50);

    "switch gateway correct" =
      assertEq "switch gateway"
        switchConfig.network.lan.gateway
        (owrtData.mkGateway 10);

    # Simple AP config structure
    "simpleAP has system config" = simpleAPConfig ? system;
    "simpleAP has network config" = simpleAPConfig ? network;
    "simpleAP has wireless config" = simpleAPConfig ? wireless;
    "simpleAP has dropbear config" = simpleAPConfig ? dropbear;

    "simpleAP hostname set" = simpleAPConfig.system.system.hostname == "test-simple";
    "simpleAP has br-lan" = simpleAPConfig.network ? br_lan;
    "simpleAP ssid set" = simpleAPConfig.wireless.ap_2g.ssid == "TestNetwork";
    "simpleAP has both radios" = simpleAPConfig.wireless ? ap_5g;

    "simpleAP lan addresses use correct VLAN" =
      assertEq "simpleAP lan addresses"
        simpleAPConfig.network.lan.ipaddr
        (owrtData.mkAddresses 31 30);

    # Router config structure
    "router has system config" = routerConfig ? system;
    "router has network config" = routerConfig ? network;
    "router has wireless config" = routerConfig ? wireless;
    "router has dropbear config" = routerConfig ? dropbear;
    "router has firewall config" = routerConfig ? firewall;
    "router has dhcp config" = routerConfig ? dhcp;

    "router hostname set" = routerConfig.system.system.hostname == "test-router";
    "router has WAN interface" = routerConfig.network ? wan;
    "router WAN proto is dhcp" = routerConfig.network.wan.proto == "dhcp";
    "router has br-lan bridge" = routerConfig.network ? br_lan;
    "router br-lan is bridge" = routerConfig.network.br_lan.type == "bridge";
    "router br-lan has vlan_filtering" = routerConfig.network.br_lan.vlan_filtering == true;

    # Router bridge-VLAN entries
    "router has MGMT bridge-vlan" = routerConfig.network ? brvlan_mgmt;
    "router has INFRA bridge-vlan" = routerConfig.network ? brvlan_infra;
    "router has HOME bridge-vlan" = routerConfig.network ? brvlan_home;
    "router has DMZ bridge-vlan" = routerConfig.network ? brvlan_dmz;
    "router HOME bridge-vlan tag" = routerConfig.network.brvlan_home.vlan == 20;
    "router HOME bridge-vlan has access port" =
      builtins.elem "lan1:u*" routerConfig.network.brvlan_home.ports;

    # Router per-VLAN interfaces with gateway addresses
    "router has home interface" = routerConfig.network ? home;
    "router has mgmt interface" = routerConfig.network ? mgmt;
    "router has infra interface" = routerConfig.network ? infra;
    "router has dmz interface" = routerConfig.network ? dmz;
    "router home device correct" = routerConfig.network.home.device == "br-lan.20";
    "router home addresses" =
      assertEq "router home addresses"
        routerConfig.network.home.ipaddr
        (owrtData.mkGatewayAddresses 20);
    "router mgmt addresses" =
      assertEq "router mgmt addresses"
        routerConfig.network.mgmt.ipaddr
        (owrtData.mkGatewayAddresses 10);

    # Router firewall
    "router firewall has defaults" = routerConfig.firewall ? defaults;
    "router firewall has WAN zone" = routerConfig.firewall ? zone_wan;
    "router firewall WAN masq" = routerConfig.firewall.zone_wan.masq == true;
    "router firewall has LAN zone" = routerConfig.firewall ? zone_lan;
    "router firewall LAN covers VLANs" =
      builtins.isList routerConfig.firewall.zone_lan.network;
    "router firewall has forwarding" = routerConfig.firewall ? fwd_lan_wan;
    "router firewall has DHCP rule" = routerConfig.firewall ? rule_wan_dhcp;

    # Router DHCP
    "router dhcp has dnsmasq" = routerConfig.dhcp ? dnsmasq;
    "router dhcp has home pool" = routerConfig.dhcp ? home;
    "router dhcp has mgmt pool" = routerConfig.dhcp ? mgmt;
    "router dhcp home interface" = routerConfig.dhcp.home.interface == "home";

    # Router wireless
    "router has both radios" = routerConfig.wireless ? radio0 && routerConfig.wireless ? radio1;
    "router has AP interfaces" = routerConfig.wireless ? ap_2g && routerConfig.wireless ? ap_5g;
    "router AP ssid set" = routerConfig.wireless.ap_2g.ssid == "TestNetwork";
    "router AP network is home" = routerConfig.wireless.ap_2g.network == "home";

    # UCI rendering produces expected commands
    "meshAP UCI sets hostname" = contains "set system.@system[0].hostname='test-mesh'" meshUCI;
    "meshAP UCI sets bat0 proto" = contains "set network.bat0.proto='batadv'" meshUCI;
    "switchAP UCI sets hostname" = contains "set system.@system[0].hostname='test-switch'" switchUCI;
    "simpleAP UCI sets hostname" = contains "set system.@system[0].hostname='test-simple'" simpleAPUCI;
    "simpleAP UCI sets ssid" = contains "ssid='TestNetwork'" simpleAPUCI;

    "router UCI sets hostname" = contains "set system.@system[0].hostname='test-router'" routerUCI;
    "router UCI sets WAN proto" = contains "set network.wan.proto='dhcp'" routerUCI;
    "router UCI sets masq" = contains "masq='1'" routerUCI;

    # Release version field
    "owrtData has defaultRelease" = owrtData ? defaultRelease;
    "defaultRelease is a string" = builtins.isString owrtData.defaultRelease;

    # Real device declarations load correctly
    "real devices has bobcat" = realDevices ? bobcat;
    "real devices has arseille" = realDevices ? arseille;
    "real devices has glorious" = realDevices ? glorious;
    "real bobcat is meshAP" = realDevices.bobcat.type == "meshAP";
    "real arseille is switch" = realDevices.arseille.type == "switch";
    "real glorious is simpleAP" = realDevices.glorious.type == "simpleAP";
    "real bobcat config generates" =
      (openwrt.mkDeviceConfig { device = realDevices.bobcat; inherit owrtData; }) ? network;
    "real derfflinger has IoT extraConfig" =
      (openwrt.mkDeviceConfig { device = realDevices.derfflinger; inherit owrtData; }).network ? iot;

    # Real bobcat-router
    "real devices has bobcat-router" = realDevices ? bobcat-router;
    "real bobcat-router is router" = realDevices.bobcat-router.type == "router";
    "real bobcat-router config generates" =
      let cfg = openwrt.mkDeviceConfig { device = realDevices.bobcat-router; inherit owrtData; };
      in cfg ? network && cfg ? firewall && cfg ? dhcp;
  };

  failures = lib.filterAttrs (_: v: !v) allTests;
  failCount = builtins.length (builtins.attrNames failures);
  passCount = builtins.length (builtins.attrNames allTests) - failCount;

in
  if failCount > 0 then
    builtins.throw "openwrt-config: ${toString failCount} test(s) failed:\n${
      lib.concatMapStringsSep "\n" (name: "  FAIL: ${name}") (builtins.attrNames failures)
    }"
  else
    pkgs.runCommand "openwrt-config-tests" {} ''
      echo "openwrt-config: ${toString passCount}/${toString passCount} tests passed"
      echo passed > $out
    ''
