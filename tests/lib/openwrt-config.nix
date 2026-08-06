# OpenWrt config generation unit tests.
#
# Pure Nix evaluation tests for lib.mk-openwrt-style module evaluation. Verifies
# that OpenWrt device modules produce the expected UCI config and build manifest.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  openwrt = import ../../lib/openwrt {inherit lib;};
  owrtData = import ../../lib/common/data/openwrt.nix {inherit lib;};

  assertEq = name: a: b:
    if a == b
    then true
    else builtins.trace "FAIL: ${name}\n  expected: ${builtins.toJSON b}\n  got:      ${builtins.toJSON a}" false;

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  mkOpenWrt = module:
    lib.evalModules {
      specialArgs = {
        inherit pkgs owrtData;
        openwrtLib = openwrt;
      };
      modules = [
        ../../hosts/openwrt/modules
        module
      ];
    };

  meshEval = mkOpenWrt {
    imports = [../../hosts/openwrt/modules/profiles/mesh-ap.nix];
    openwrt = {
      hostname = "test-mesh";
      image = {
        profile = "linksys_e8450-ubi";
        target = "mediatek";
        subtarget = "mt7622";
      };
      device.hostId = 99;
      mesh = {
        heBssColor = 42;
        legacyRates = true;
      };
    };
  };

  switchEval = mkOpenWrt {
    imports = [../../hosts/openwrt/modules/profiles/switch.nix];
    openwrt = {
      hostname = "test-switch";
      image = {
        profile = "netgear_gs108t-v3";
        target = "realtek";
        subtarget = "rtl838x";
      };
      device.hostId = 50;
      switch.vlanId = 10;
    };
  };

  simpleEval = mkOpenWrt {
    imports = [../../hosts/openwrt/modules/profiles/simple-ap.nix];
    openwrt = {
      hostname = "test-simple";
      image = {
        profile = "tplink_eap615-wall-v1";
        target = "ramips";
        subtarget = "mt7621";
      };
      device.hostId = 30;
      simpleAP.vlanId = 31;
    };
  };

  meshExtraEval = mkOpenWrt {
    imports = [../../hosts/openwrt/modules/profiles/mesh-ap.nix];
    openwrt = {
      hostname = "test-mesh-extra";
      image = {
        profile = "linksys_e8450-ubi";
        target = "mediatek";
        subtarget = "mt7622";
      };
      device.hostId = 99;
      uci.extraConfig.network.custom = {
        _type = "interface";
        proto = "static";
        device = "bat0.1040";
      };
    };
  };

  meshConfig = meshEval.config.openwrt.uci.finalConfig;
  switchConfig = switchEval.config.openwrt.uci.finalConfig;
  simpleConfig = simpleEval.config.openwrt.uci.finalConfig;
  meshExtraConfig = meshExtraEval.config.openwrt.uci.finalConfig;

  meshUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs meshConfig);
  switchUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs switchConfig);
  simpleUCI = lib.concatStringsSep "\n" (openwrt.uci.renderConfigs simpleConfig);

  meshManifest = meshEval.config.openwrt.build.manifest;
  switchManifest = switchEval.config.openwrt.build.manifest;
  simpleManifest = simpleEval.config.openwrt.build.manifest;

  realModules = import ../../hosts/openwrt;
  realEvals = builtins.mapAttrs (_: mkOpenWrt) realModules;
  realConfigs = builtins.mapAttrs (_: eval: eval.config.openwrt.uci.finalConfig) realEvals;
  realInfo = builtins.mapAttrs (_: eval: eval.config.openwrt.deviceInfo) realEvals;

  allTests = {
    # Mesh AP config structure
    "meshAP has system config" = meshConfig ? system;
    "meshAP has network config" = meshConfig ? network;
    "meshAP has wireless config" = meshConfig ? wireless;
    "meshAP has dropbear config" = meshConfig ? dropbear;
    "meshAP role set by profile" = meshEval.config.openwrt.device.role == "meshAP";
    "meshAP hostname set" = meshConfig.system.system.hostname == "test-mesh";
    "meshAP timezone is UTC" = meshConfig.system.system.timezone == "UTC";
    "meshAP has bat0" = meshConfig.network ? bat0;
    "meshAP bat0 is batadv" = meshConfig.network.bat0.proto == "batadv";
    "meshAP has br-lan bridge" = meshConfig.network ? br_lan;
    "meshAP has mgmt bridge" = meshConfig.network ? br_mgmt;
    "meshAP has admin bridge" = meshConfig.network ? br_admin;
    "meshAP has mesh interface" = meshConfig.wireless ? batmesh;
    "meshAP batmesh has encryption" = meshConfig.wireless.batmesh.encryption == "sae";
    "meshAP has he_bss_color" = meshConfig.wireless.radio1.he_bss_color == 42;
    "meshAP has legacy_rates" = meshConfig.wireless.radio0.legacy_rates;
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
    "meshAP dropbear disables password auth" = !meshConfig.dropbear.main.PasswordAuth;
    "meshAP extra config merged" = meshExtraConfig.network ? custom;
    "meshAP extra config device" = meshExtraConfig.network.custom.device == "bat0.1040";

    # Switch config structure
    "switch has system config" = switchConfig ? system;
    "switch has network config" = switchConfig ? network;
    "switch has no wireless" = !(switchConfig ? wireless);
    "switch has dropbear config" = switchConfig ? dropbear;
    "switch role set by profile" = switchEval.config.openwrt.device.role == "switch";
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
    "simpleAP has system config" = simpleConfig ? system;
    "simpleAP has network config" = simpleConfig ? network;
    "simpleAP has wireless config" = simpleConfig ? wireless;
    "simpleAP has dropbear config" = simpleConfig ? dropbear;
    "simpleAP role set by profile" = simpleEval.config.openwrt.device.role == "simpleAP";
    "simpleAP hostname set" = simpleConfig.system.system.hostname == "test-simple";
    "simpleAP has br-lan" = simpleConfig.network ? br_lan;
    "simpleAP has both radios" = simpleConfig.wireless ? ap_5g_main;
    "simpleAP lan addresses use correct VLAN" =
      assertEq "simpleAP lan addresses"
      simpleConfig.network.lan.ipaddr
      (owrtData.mkAddresses 31 30);

    # UCI rendering produces expected commands (named sections)
    "meshAP UCI sets hostname" = contains "set system.system.hostname='test-mesh'" meshUCI;
    "meshAP UCI sets bat0 proto" = contains "set network.bat0.proto='batadv'" meshUCI;
    "switch UCI sets hostname" = contains "set system.system.hostname='test-switch'" switchUCI;
    "simpleAP UCI sets hostname" = contains "set system.system.hostname='test-simple'" simpleUCI;

    # Secret fields declared as _secret markers and collected into manifest.
    "meshAP batmesh mesh_id is a secret marker" = meshConfig.wireless.batmesh.mesh_id ? _secret;
    "meshAP batmesh key is a secret marker" = meshConfig.wireless.batmesh.key ? _secret;
    "meshAP ap_2g_main ssid is a secret marker" = meshConfig.wireless.ap_2g_main.ssid ? _secret;
    "simpleAP ap_2g_main ssid is a secret marker" = simpleConfig.wireless.ap_2g_main.ssid ? _secret;
    "meshAP secrets has wifi.mesh.id" = meshEval.config.openwrt.uci.secretsMap ? "wifi.mesh.id";
    "meshAP secrets has wifi.main.ssid" = meshEval.config.openwrt.uci.secretsMap ? "wifi.main.ssid";
    "meshAP secrets wifi.mesh.id targets batmesh" =
      builtins.elem "wireless.batmesh.mesh_id" meshEval.config.openwrt.uci.secretsMap."wifi.mesh.id";
    "meshAP secrets wifi.main.ssid targets both bands" =
      builtins.length meshEval.config.openwrt.uci.secretsMap."wifi.main.ssid" == 2;
    "switch secrets map is empty" = switchEval.config.openwrt.uci.secretsMap == {};
    "simpleAP secrets has wifi.main.key" = simpleEval.config.openwrt.uci.secretsMap ? "wifi.main.key";

    # Radios are fail-safe in the manifest and enabled only after every required
    # Wi-Fi secret has been validated and applied by the runtime builder.
    "meshAP radio0 disabled=true" = meshConfig.wireless.radio0.disabled;
    "meshAP radio1 disabled=true" = meshConfig.wireless.radio1.disabled;
    "simpleAP radio0 disabled=true" = simpleConfig.wireless.radio0.disabled;

    # Named sections (no _anonymous in generated config)
    "meshAP batmesh is named" = !(meshConfig.wireless.batmesh ? _anonymous);
    "meshAP system is named" = !(meshConfig.system.system ? _anonymous);

    # Build manifests
    "meshAP manifest hostname" = meshManifest.hostname == "test-mesh";
    "meshAP manifest deviceType" = meshManifest.deviceType == "meshAP";
    "meshAP manifest target correct" = meshManifest.target == "mediatek";
    "meshAP manifest subtarget correct" = meshManifest.subtarget == "mt7622";
    "meshAP manifest release is string" = builtins.isString meshManifest.release;
    "meshAP manifest has packages" = builtins.isList meshManifest.packages;
    "meshAP manifest has secretsMap" = meshManifest ? secretsMap;
    "meshAP manifest has uciDefaults" = meshManifest ? uciDefaults;
    "switch manifest deviceType" = switchManifest.deviceType == "switch";
    "simpleAP manifest deviceType" = simpleManifest.deviceType == "simpleAP";

    # Flake-visible BT8 bridge.
    "real devices contains only bt8bridge" = builtins.attrNames realModules == ["bt8bridge"];
    "real bt8bridge hostname is correct" = realInfo.bt8bridge.hostname == "bt8bridge";
    "real bt8bridge role is wirelessBridge" = realInfo.bt8bridge.role == "wirelessBridge";
    "real bt8bridge target is mediatek" = realInfo.bt8bridge.target == "mediatek";
    "real bt8bridge subtarget is filogic" = realInfo.bt8bridge.subtarget == "filogic";
    "real bt8bridge uses stock profile" = realInfo.bt8bridge.profile == "asus_zenwifi-bt8";
    "real bt8bridge profile is not ubootmod" = !(contains "ubootmod" realInfo.bt8bridge.profile);
    "real bt8bridge uses 25.12.5" = realInfo.bt8bridge.release == "25.12.5";
    "real bt8bridge has three radios" = lib.all (name: realConfigs.bt8bridge.wireless ? ${name}) ["radio0" "radio1" "radio2"];
    "real bt8bridge mesh uses radio2" = realConfigs.bt8bridge.wireless.batmesh.device == "radio2";
    "real bt8bridge mesh is EHT80 channel 85" = realConfigs.bt8bridge.wireless.radio2.htmode == "EHT80" && realConfigs.bt8bridge.wireless.radio2.channel == 85;
    "real bt8bridge uses GB policy" = realConfigs.bt8bridge.wireless.radio2.country == "GB";
    "real bt8bridge disables mesh forwarding" = !realConfigs.bt8bridge.wireless.batmesh.mesh_fwding;
    "real bt8bridge wired hardif is WAN" = realConfigs.bt8bridge.network.wired.device == "wan";
    "real bt8bridge LAN1 is management recovery access" = realConfigs.bt8bridge.network.br_mgmt.ports == ["bat0.10" "lan1"];
    "real bt8bridge LAN2 and LAN3 are HOME access" = realConfigs.bt8bridge.network.br_home.ports == ["bat0.20" "lan2" "lan3"];
    "real bt8bridge has three guest APs" = lib.all (name: realConfigs.bt8bridge.wireless.${name}.network == "guest_l2") ["guest_main" "guest_secondary" "game"];
    "real bt8bridge management address" = realConfigs.bt8bridge.network.mgmt.ipaddr == "10.91.10.4";
    "real bt8bridge password auth disabled" = !realConfigs.bt8bridge.dropbear.main.PasswordAuth && !realConfigs.bt8bridge.dropbear.main.RootPasswordAuth;
    "real bt8bridge enables all radios after secrets" = realEvals.bt8bridge.config.openwrt.uci.radiosToEnable == ["radio0" "radio1" "radio2"];
    "real bt8bridge uses device scoped mesh secret" = realEvals.bt8bridge.config.openwrt.uci.secretsMap ? "bt8bridge.mesh.id";
    "real bt8bridge uses device scoped game secret" = realEvals.bt8bridge.config.openwrt.uci.secretsMap ? "bt8bridge.aps.game.key";
    "all real devices have target" =
      lib.all (d: d ? target && d ? subtarget) (builtins.attrValues realInfo);
    "all real devices produce build manifests" = lib.all (
      name: let
        manifest = realEvals.${name}.config.openwrt.build.manifest;
      in
        manifest ? hostname && manifest ? profile && manifest ? target && manifest ? packages
    ) (builtins.attrNames realEvals);

    # migrationPreCommands is exported
    "migrationPreCommands is exported" = openwrt ? migrationPreCommands;
    "migrationPreCommands is a list" = builtins.isList openwrt.migrationPreCommands;
    "migrationPreCommands is non-empty" = builtins.length openwrt.migrationPreCommands > 0;
    "migration removes intrinsic network config" =
      lib.any (lib.hasPrefix "uci -q show network") openwrt.migrationPreCommands;
  };

  failures = lib.filterAttrs (_: v: !v) allTests;
  failCount = builtins.length (builtins.attrNames failures);
  passCount = builtins.length (builtins.attrNames allTests) - failCount;
in
  if failCount > 0
  then
    builtins.throw "openwrt-config: ${toString failCount} test(s) failed:\n${
      lib.concatMapStringsSep "\n" (name: "  FAIL: ${name}") (builtins.attrNames failures)
    }"
  else
    pkgs.runCommand "openwrt-config-tests" {} ''
      echo "openwrt-config: ${toString passCount}/${toString passCount} tests passed"
      echo passed > $out
    ''
