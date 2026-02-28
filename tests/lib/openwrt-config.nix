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

  # --- Render to UCI commands ---

  meshUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs meshConfig);
  switchUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs switchConfig);
  simpleAPUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs simpleAPConfig);

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

    # UCI rendering produces expected commands
    "meshAP UCI sets hostname" = contains "set system.@system[0].hostname='test-mesh'" meshUCI;
    "meshAP UCI sets bat0 proto" = contains "set network.bat0.proto='batadv'" meshUCI;
    "switchAP UCI sets hostname" = contains "set system.@system[0].hostname='test-switch'" switchUCI;
    "simpleAP UCI sets hostname" = contains "set system.@system[0].hostname='test-simple'" simpleAPUCI;
    "simpleAP UCI sets ssid" = contains "ssid='TestNetwork'" simpleAPUCI;

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
