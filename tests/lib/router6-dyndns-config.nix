# Dynamic DNS configuration eval test for router6
#
# Pure Nix evaluation tests verifying:
# - systemd service and timer generation
# - Script content (curl, server URL, hosts, domain handling)
# - Interface inference from DHCP topology
# - Explicit interface override
# - domainFile vs domain
# - Custom renewPeriod
# - Disabled state
#
# Run: nix-instantiate --eval --strict tests/lib/router6-dyndns-config.nix
# Or:  nix build .#checks.x86_64-linux.router6-dyndns-config
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

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  assertEq = name: a: b:
    if a == b
    then true
    else throw "FAIL: ${name}\n  Expected: ${builtins.toJSON b}\n  Got:      ${builtins.toJSON a}";

  baseTopology = {
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

  mkConfig = extra: baseTopology // extra;

  # Config A: Basic Namecheap dyndns (DHCP WAN, auto-inferred interface)
  evalA = evalConfig (mkConfig {
    dyndns = {
      enable = true;
      protocol = "namecheap";
      server = "https://dynamicdns.park-your-domain.com";
      hosts = ["@" "www"];
      domain = "example.com";
      passwordFile = "/run/secrets/ddns-password";
    };
  });
  scriptA = evalA.systemd.services.router6-dyndns.script;

  # Config B: Explicit interface
  evalB = evalConfig (mkConfig {
    dyndns = {
      enable = true;
      protocol = "namecheap";
      server = "https://dynamicdns.park-your-domain.com";
      hosts = ["@"];
      domain = "example.com";
      passwordFile = "/run/secrets/ddns-password";
      interface = "wan";
    };
  });
  scriptB = evalB.systemd.services.router6-dyndns.script;

  # Config C: domainFile instead of domain
  evalC = evalConfig (mkConfig {
    dyndns = {
      enable = true;
      protocol = "namecheap";
      server = "https://dynamicdns.park-your-domain.com";
      hosts = ["@"];
      domainFile = "/run/secrets/ddns-domain";
      passwordFile = "/run/secrets/ddns-password";
    };
  });
  scriptC = evalC.systemd.services.router6-dyndns.script;

  # Config D: Custom renewPeriod
  evalD = evalConfig (mkConfig {
    dyndns = {
      enable = true;
      protocol = "namecheap";
      server = "https://dynamicdns.park-your-domain.com";
      hosts = ["@"];
      domain = "example.com";
      passwordFile = "/run/secrets/ddns-password";
      renewPeriod = "30m";
    };
  });

  # Config E: dyndns disabled
  evalE = evalConfig (mkConfig {
    dyndns.enable = false;
  });

  tests = [
    # Config A: Basic Namecheap dyndns
    (assertTrue "A: router6-dyndns service exists"
      (builtins.hasAttr "router6-dyndns" evalA.systemd.services))

    (assertTrue "A: router6-dyndns timer exists"
      (builtins.hasAttr "router6-dyndns" evalA.systemd.timers))

    (assertEq "A: timer OnBootSec = 60m"
      evalA.systemd.timers.router6-dyndns.timerConfig.OnBootSec
      "60m")

    (assertEq "A: timer OnUnitActiveSec = 60m"
      evalA.systemd.timers.router6-dyndns.timerConfig.OnUnitActiveSec
      "60m")

    (assertTrue "A: script contains curl"
      (contains "curl" scriptA))

    (assertTrue "A: script contains server URL"
      (contains "dynamicdns.park-your-domain.com" scriptA))

    (assertTrue "A: script contains example.com domain"
      (contains "example.com" scriptA))

    (assertTrue "A: script contains host @"
      (contains ''"@"'' scriptA))

    (assertTrue "A: script contains host www"
      (contains ''"www"'' scriptA))

    # Config B: Explicit interface
    (assertTrue "B: script contains ip -4 a show wan"
      (contains "ip -4 a show wan" scriptB))

    # Config C: domainFile
    (assertTrue "C: script contains cat /run/secrets/ddns-domain"
      (contains "cat /run/secrets/ddns-domain" scriptC))

    # Config D: Custom renewPeriod
    (assertEq "D: timer OnUnitActiveSec = 30m"
      evalD.systemd.timers.router6-dyndns.timerConfig.OnUnitActiveSec
      "30m")

    (assertEq "D: timer OnBootSec = 30m"
      evalD.systemd.timers.router6-dyndns.timerConfig.OnBootSec
      "30m")

    # Config E: dyndns disabled
    (assertTrue "E: router6-dyndns service absent"
      (!(builtins.hasAttr "router6-dyndns" evalE.systemd.services)))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-dyndns-config" {} ''
      echo "All ${toString (builtins.length tests)} dyndns config tests passed"
      echo "PASS" > $out
    ''
  else throw "Dyndns config tests failed"
