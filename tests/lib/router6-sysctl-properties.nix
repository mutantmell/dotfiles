# Sysctl property tests for router6
#
# Pure Nix evaluation tests verifying kernel hardening:
# - IPv4/IPv6 forwarding enabled
# - Strict reverse path filtering (rp_filter)
# - RA acceptance controlled per-interface
#
# Run: nix-instantiate --eval --strict tests/lib/router6-sysctl-properties.nix
# Or:  nix build .#checks.x86_64-linux.router6-sysctl-properties
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

  # DHCP WAN config
  dhcpWanConfig = {
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

  # Static WAN config
  staticWanConfig = {
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
    };
    topology = {
      wan = {
        hardwareName = "eth0";
        network = {
          type = "static";
          addresses = ["203.0.113.1/24"];
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

  dhcpSysctl = (evalConfig dhcpWanConfig).boot.kernel.sysctl;
  staticSysctl = (evalConfig staticWanConfig).boot.kernel.sysctl;

  tests = [
    # IPv4/IPv6 forwarding enabled
    (assertEq "IPv4 forwarding enabled"
      dhcpSysctl."net.ipv4.conf.all.forwarding"
      true)

    (assertEq "IPv6 forwarding enabled"
      dhcpSysctl."net.ipv6.conf.all.forwarding"
      true)

    # Strict reverse path filtering
    (assertEq "rp_filter default = 1 (strict)"
      dhcpSysctl."net.ipv4.conf.default.rp_filter"
      1)

    (assertEq "rp_filter all = 1 (strict)"
      dhcpSysctl."net.ipv4.conf.all.rp_filter"
      1)

    # RA acceptance: global disabled
    (assertEq "accept_ra all = 0"
      dhcpSysctl."net.ipv6.conf.all.accept_ra"
      0)

    (assertEq "accept_ra default = 0"
      dhcpSysctl."net.ipv6.conf.default.accept_ra"
      0)

    # DHCP WAN: per-interface RA override
    (assertEq "DHCP WAN: accept_ra = 2 (per-interface override)"
      dhcpSysctl."net.ipv6.conf.wan.accept_ra"
      2)

    # Static WAN: no per-interface RA override
    (assertTrue "Static WAN: no accept_ra override"
      (!(builtins.hasAttr "net.ipv6.conf.wan.accept_ra" staticSysctl)))

    # Static config has same base sysctls
    (assertEq "Static: IPv4 forwarding enabled"
      staticSysctl."net.ipv4.conf.all.forwarding"
      true)

    (assertEq "Static: IPv6 forwarding enabled"
      staticSysctl."net.ipv6.conf.all.forwarding"
      true)
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-sysctl-properties" {} ''
      echo "All ${toString (builtins.length tests)} sysctl property tests passed"
      echo "PASS" > $out
    ''
  else throw "Sysctl property tests failed"
