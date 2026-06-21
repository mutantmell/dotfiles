# Eval test for router6 downstream DHCPv6 Prefix Delegation.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-downstream-prefix-delegation.nix
# Or:  nix build .#checks.x86_64-linux.router6-downstream-prefix-delegation
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

  assertEq = name: a: b:
    if a == b
    then true
    else throw "FAIL: ${name}\n  Expected: ${builtins.toJSON b}\n  Got:      ${builtins.toJSON a}";

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  cfg = evalConfig {
    zones = {
      external = {
        icmpEcho = "disable";
        accessTo = [];
        inputRules = [];
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
          ipv6PrefixDelegation = {
            enable = true;
            prefixLength = 56;
          };
        };
      };
      brTRANSIT = {
        kind = "bridge";
        members = [];
        network = {
          type = "static";
          addresses = ["10.255.255.1/30" "fdc6:55f2:0a5e:ffff::1/64"];
          zone = "transit";
        };
      };
    };

    downstreamPrefixDelegations.bt8gw = {
      sourceInterface = "wan";
      interface = "brTRANSIT";
      linkSubnet6 = "fdc6:55f2:0a5e:ffff::/64";
      delegatedLength = 57;
      childIndex = 1;
      refreshInterval = "7min";
    };
  };

  service = cfg.systemd.services.router6-downstream-pd-bt8gw;
  refreshService = cfg.systemd.services.router6-downstream-pd-bt8gw-refresh;
  timer = cfg.systemd.timers.router6-downstream-pd-bt8gw-refresh;

  tests = [
    (assertEq "delegation service description"
      service.description
      "Router6 downstream DHCPv6-PD server for bt8gw")

    (assertEq "delegation service wanted by multi-user"
      service.wantedBy
      ["multi-user.target"])

    (assertEq "delegation service has route capability"
      service.serviceConfig.AmbientCapabilities
      ["CAP_NET_ADMIN"])

    (assertTrue "delegation service runs kea-dhcp6"
      (lib.hasInfix "kea-dhcp6 -c /run/router6-downstream-pd/bt8gw/kea-dhcp6.json" service.script))

    (assertEq "refresh service is oneshot"
      refreshService.serviceConfig.Type
      "oneshot")

    (assertEq "refresh timer uses configured interval"
      timer.timerConfig.OnUnitActiveSec
      "7min")

    (assertEq "refresh timer restarts refresh service"
      timer.timerConfig.Unit
      "router6-downstream-pd-bt8gw-refresh.service")
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-downstream-prefix-delegation" {} ''
      renderer="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*render-router6-downstream-pd-bt8gw.py' <<'EOF'
      ${service.script}
      EOF
      )"
      ${pkgs.gnugrep}/bin/grep -q 'DHCPv6Client' "$renderer"
      ${pkgs.gnugrep}/bin/grep -q 'Prefixes' "$renderer"
      ${pkgs.gnugrep}/bin/grep -q 'PrefixString' "$renderer"
      ${pkgs.gnugrep}/bin/grep -q 'PrefixLength' "$renderer"
      ! ${pkgs.gnugrep}/bin/grep -q 'PREFIX_RE' "$renderer"
      echo "All ${toString (builtins.length tests)} router6.downstreamPrefixDelegations tests passed"
      echo "PASS" > $out
    ''
  else throw "router6.downstreamPrefixDelegations tests failed"
