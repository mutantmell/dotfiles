# UCI rendering layer unit tests
#
# Pure Nix evaluation tests for lib/openwrt/uci.nix — verifies that
# Nix attribute sets produce the expected UCI batch commands.
#
# Run: nix-instantiate --eval --strict tests/lib/uci-rendering.nix
# Or:  nix build .#checks.x86_64-linux.uci-rendering
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  uci = import ../../lib/openwrt/uci.nix {inherit lib;};

  assertEq = name: a: b:
    if a == b
    then true
    else builtins.trace "FAIL: ${name}\n  expected: ${builtins.toJSON b}\n  got:      ${builtins.toJSON a}" false;

  # --- escapeUCI ---

  escPlain = assertEq "escapeUCI plain" (uci.escapeUCI "hello") "hello";
  escQuote = assertEq "escapeUCI single quote" (uci.escapeUCI "it's") "it'\\''s";
  escInt = assertEq "escapeUCI int" (uci.escapeUCI 42) "42";

  # --- toUCIValue ---

  valTrue = assertEq "toUCIValue true" (uci.toUCIValue true) "1";
  valFalse = assertEq "toUCIValue false" (uci.toUCIValue false) "0";
  valInt = assertEq "toUCIValue int" (uci.toUCIValue 8080) "8080";
  valStr = assertEq "toUCIValue string" (uci.toUCIValue "foo") "foo";

  # --- isSecret ---

  secretYes = assertEq "isSecret marker" (uci.isSecret {_secret = "wifi.key";}) true;
  secretNo = assertEq "isSecret plain" (uci.isSecret "foo") false;
  secretNoAttrs = assertEq "isSecret non-secret attrs" (uci.isSecret {name = "x";}) false;

  # --- renderOption ---

  optStr =
    assertEq "renderOption string"
    (uci.renderOption {
      config = "network";
      section = "lan";
      key = "proto";
      value = "static";
    })
    ["set network.lan.proto='static'"];

  optBool =
    assertEq "renderOption bool"
    (uci.renderOption {
      config = "network";
      section = "wan";
      key = "disabled";
      value = true;
    })
    ["set network.wan.disabled='1'"];

  optInt =
    assertEq "renderOption int"
    (uci.renderOption {
      config = "network";
      section = "lan";
      key = "mtu";
      value = 1500;
    })
    ["set network.lan.mtu='1500'"];

  optList =
    assertEq "renderOption list"
    (uci.renderOption {
      config = "network";
      section = "lan";
      key = "dns";
      value = ["1.1.1.1" "8.8.8.8"];
    })
    [
      "add_list network.lan.dns='1.1.1.1'"
      "add_list network.lan.dns='8.8.8.8'"
    ];

  optQuote =
    assertEq "renderOption quote escaping"
    (uci.renderOption {
      config = "system";
      section = "sys";
      key = "note";
      value = "it's a test";
    })
    ["set system.sys.note='it'\\''s a test'"];

  # --- renderSectionOptions ---

  sectOpts =
    assertEq "renderSectionOptions skips null and secrets"
    (uci.renderSectionOptions {
      config = "network";
      section = "lan";
      options = {
        proto = "static";
        hidden = null;
        key = {_secret = "wifi.key";};
        ipaddr = "10.0.0.1";
      };
    })
    [
      "set network.lan.ipaddr='10.0.0.1'"
      "set network.lan.proto='static'"
    ];

  # --- renderNamedSection ---

  named =
    assertEq "renderNamedSection"
    (uci.renderNamedSection {
      config = "network";
      name = "lan";
      type = "interface";
      options = {
        proto = "static";
        ipaddr = "192.168.1.1";
      };
    })
    [
      "set network.lan=interface"
      "set network.lan.ipaddr='192.168.1.1'"
      "set network.lan.proto='static'"
    ];

  # --- renderAnonymousSection ---

  anon = let
    result = uci.renderAnonymousSection {
      config = "firewall";
      type = "rule";
      options = {
        name = "Allow-DNS";
        target = "ACCEPT";
        dest_port = 53;
      };
      index = 0;
    };
  in
    (assertEq "renderAnonymousSection commands"
      result.commands
      [
        "add firewall rule"
        "set firewall.@rule[0].dest_port='53'"
        "set firewall.@rule[0].name='Allow-DNS'"
        "set firewall.@rule[0].target='ACCEPT'"
      ])
    && (assertEq "renderAnonymousSection nextIndex" result.nextIndex 1);

  # --- renderConfig ---

  configMixed =
    assertEq "renderConfig named + anonymous"
    (uci.renderConfig "firewall" {
      defaults = {
        _type = "defaults";
        forward = "DROP";
        input = "ACCEPT";
      };
      allow_dns = {
        _type = "rule";
        _anonymous = true;
        name = "Allow-DNS";
        target = "ACCEPT";
      };
    })
    [
      "set firewall.defaults=defaults"
      "set firewall.defaults.forward='DROP'"
      "set firewall.defaults.input='ACCEPT'"
      "add firewall rule"
      "set firewall.@rule[0].name='Allow-DNS'"
      "set firewall.@rule[0].target='ACCEPT'"
    ];

  # --- renderConfigs ---

  multiConfig = let
    commands = uci.renderConfigs {
      system = {
        sys = {
          _type = "system";
          hostname = "router";
        };
      };
      network = {
        loopback = {
          _type = "interface";
          proto = "static";
        };
      };
    };
  in
    # Both configs should appear (order may vary between configs)
    (assertEq "renderConfigs contains network"
      (builtins.elem "set network.loopback=interface" commands)
      true)
    && (assertEq "renderConfigs contains system"
      (builtins.elem "set system.sys=system" commands)
      true)
    && (assertEq "renderConfigs total count" (builtins.length commands) 4);

  # --- mkUCIDefaultsScript ---

  script = uci.mkUCIDefaultsScript {
    name = "test-config";
    commands = ["set network.lan=interface" "set network.lan.proto='static'"];
    preCommands = ["echo pre"];
    postCommands = ["echo post"];
  };
  scriptHasUci =
    assertEq "script has uci commands"
    (builtins.match ".*uci -q set network.lan=interface.*" script != null)
    true;
  scriptHasPre =
    assertEq "script has pre commands"
    (builtins.match ".*echo pre.*" script != null)
    true;
  scriptHasPost =
    assertEq "script has post commands"
    (builtins.match ".*echo post.*" script != null)
    true;
  scriptHasCommit =
    assertEq "script has uci commit"
    (builtins.match ".*uci commit.*" script != null)
    true;

  # --- Multiple anonymous sections of same type get incrementing indices ---

  anonIndices =
    assertEq "anonymous sections increment index"
    (uci.renderConfig "firewall" {
      rule1 = {
        _type = "rule";
        _anonymous = true;
        name = "first";
      };
      rule2 = {
        _type = "rule";
        _anonymous = true;
        name = "second";
      };
    })
    [
      "add firewall rule"
      "set firewall.@rule[0].name='first'"
      "add firewall rule"
      "set firewall.@rule[1].name='second'"
    ];

  # --- Edge cases ---

  emptyList =
    assertEq "renderOption empty list"
    (uci.renderOption {
      config = "net";
      section = "s";
      key = "k";
      value = [];
    })
    [];

  boolList =
    assertEq "renderOption list of bools"
    (uci.renderOption {
      config = "net";
      section = "s";
      key = "flags";
      value = [true false];
    })
    [
      "add_list net.s.flags='1'"
      "add_list net.s.flags='0'"
    ];

  allTests = {
    "escapeUCI plain string" = escPlain;
    "escapeUCI single quote" = escQuote;
    "escapeUCI int coercion" = escInt;
    "toUCIValue true" = valTrue;
    "toUCIValue false" = valFalse;
    "toUCIValue int" = valInt;
    "toUCIValue string" = valStr;
    "isSecret detects marker" = secretYes;
    "isSecret rejects string" = secretNo;
    "isSecret rejects non-secret attrs" = secretNoAttrs;
    "renderOption string" = optStr;
    "renderOption bool" = optBool;
    "renderOption int" = optInt;
    "renderOption list" = optList;
    "renderOption quote escaping" = optQuote;
    "renderSectionOptions skips null and secrets" = sectOpts;
    "renderNamedSection" = named;
    "renderAnonymousSection" = anon;
    "renderConfig named + anonymous" = configMixed;
    "renderConfigs multi" = multiConfig;
    "script has uci commands" = scriptHasUci;
    "script has pre commands" = scriptHasPre;
    "script has post commands" = scriptHasPost;
    "script has uci commit" = scriptHasCommit;
    "anonymous index incrementing" = anonIndices;
    "empty list" = emptyList;
    "bool list" = boolList;
  };

  failures = lib.filterAttrs (_: v: !v) allTests;
  failCount = builtins.length (builtins.attrNames failures);
  passCount = builtins.length (builtins.attrNames allTests) - failCount;
in
  if failCount > 0
  then
    builtins.throw "uci-rendering: ${toString failCount} test(s) failed:\n${
      lib.concatMapStringsSep "\n" (name: "  FAIL: ${name}") (builtins.attrNames failures)
    }"
  else
    pkgs.runCommand "uci-rendering-tests" {} ''
      echo "uci-rendering: ${toString passCount}/${toString passCount} tests passed"
      echo passed > $out
    ''
