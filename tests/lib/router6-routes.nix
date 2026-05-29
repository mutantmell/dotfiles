# Static-routes eval test for router6
#
# Pure Nix evaluation tests verifying that `router6.routes` lands on the
# correct systemd-networkd network file with the expected route attrs.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-routes.nix
# Or:  nix build .#checks.x86_64-linux.router6-routes
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
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

  evalAssertions = router6Config:
    (evalConfig router6Config).assertions or [];

  evalFailures = cfg:
    builtins.filter (a: !a.assertion) (evalAssertions cfg);

  assertEq = name: a: b:
    if a == b
    then true
    else throw "FAIL: ${name}\n  Expected: ${builtins.toJSON b}\n  Got:      ${builtins.toJSON a}";

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  # Base config: dual-gateway shape with a transit bridge and a few zones.
  baseConfig = {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["1.1.1.1"];
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
      };
      trusted = {
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [{verdict = "accept";}];
      };
      transit = {
        icmpEcho = "enable";
        accessTo = ["external"];
        inputRules = [];
      };
    };
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "dhcp";
          zone = "external";
          nat.enable = true;
        };
      };
      lanPhy = {
        hardwareName = "eth1";
        network.type = "disabled";
      };
      transitPhy = {
        hardwareName = "eth2";
        network.type = "disabled";
      };
      brTRANSIT = {
        kind = "bridge";
        members = ["transitPhy"];
        network = {
          type = "static";
          addresses = ["10.255.255.1/30" "fdc6:55f2:0a5e:ffff::1/64"];
          zone = "transit";
        };
      };
      brLAN = {
        kind = "bridge";
        members = ["lanPhy"];
        network = {
          type = "static";
          addresses = ["10.0.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
        };
      };
    };
  };

  withRoutes = routes: baseConfig // {inherit routes;};

  # Positive: cross-gateway v4 + v6 routes land on brTRANSIT's network file.
  goodCfg = withRoutes [
    {
      destination = "10.97.0.0/16";
      gateway = "10.255.255.2";
      interface = "brTRANSIT";
    }
    {
      destination = "fdc6:55f2:0a5e:1000::/52";
      gateway = "fdc6:55f2:0a5e:ffff::2";
      interface = "brTRANSIT";
    }
  ];

  goodConfig = evalConfig goodCfg;
  transitNet = goodConfig.systemd.network.networks."10-brTRANSIT" or null;
  transitRoutes = transitNet.routes or [];

  # Metric optionality.
  metricCfg = withRoutes [
    {
      destination = "192.0.2.0/24";
      gateway = "10.0.10.254";
      interface = "brLAN";
      metric = 200;
    }
  ];
  metricRoutes = (evalConfig metricCfg).systemd.network.networks."10-brLAN".routes;

  # Negative: route on a non-existent interface should fail the assertion.
  badCfg = withRoutes [
    {
      destination = "10.97.0.0/16";
      gateway = "10.255.255.2";
      interface = "doesNotExist";
    }
  ];

  tests = [
    (assertTrue "good cfg evaluates with no assertion failures"
      ((evalFailures goodCfg) == []))

    (assertTrue "brTRANSIT network file exists"
      (transitNet != null))

    (assertEq "two routes attached to brTRANSIT"
      (builtins.length transitRoutes)
      2)

    (assertEq "v4 route Destination matches"
      (builtins.elemAt transitRoutes 0).Destination
      "10.97.0.0/16")

    (assertEq "v4 route Gateway matches"
      (builtins.elemAt transitRoutes 0).Gateway
      "10.255.255.2")

    (assertEq "v6 route Destination matches"
      (builtins.elemAt transitRoutes 1).Destination
      "fdc6:55f2:0a5e:1000::/52")

    (assertEq "v6 route Gateway matches"
      (builtins.elemAt transitRoutes 1).Gateway
      "fdc6:55f2:0a5e:ffff::2")

    (assertTrue "no Metric emitted when null"
      (!(builtins.elemAt transitRoutes 0 ? Metric)))

    (assertEq "Metric emitted when set"
      (builtins.elemAt metricRoutes 0).Metric
      200)

    (assertTrue "unknown interface produces an assertion failure"
      ((evalFailures badCfg) != []))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-routes" {} ''
      echo "All ${toString (builtins.length tests)} router6.routes tests passed"
      echo "PASS" > $out
    ''
  else throw "router6.routes tests failed"
