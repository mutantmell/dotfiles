# kresd DNS config tests for router6
#
# Pure Nix evaluation tests verifying kresd Lua configuration:
# - Upstream DNS with/without fallback
# - DHCP fallback code paths
# - Static fallback list
# - DNSSEC toggle
# - localDomain isolation
#
# Run: nix-instantiate --eval --strict tests/lib/router6-kresd-config.nix
# Or:  nix build .#checks.x86_64-linux.router6-kresd-config
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
  notContains = needle: haystack: !contains needle haystack;

  assertTrue = name: v:
    if v
    then true
    else throw "FAIL: ${name}";

  baseTopology = {
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
    ulaPrefix = "fdc6:55f2:0a5e::/48";
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

  # Config A: Simple upstream, no fallback
  configA =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        useDHCPFallback = false;
      };
    };

  # Config B: Upstream with DHCP fallback
  configB =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        useDHCPFallback = true;
      };
    };

  # Config C: Upstream with static fallback list
  configC =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        fallback = ["8.8.8.8"];
        useDHCPFallback = false;
      };
    };

  # Config D: DNSSEC disabled
  configD =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        useDHCPFallback = false;
        enableDNSSEC = false;
      };
    };

  # Config E: localDomain set
  configE =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        useDHCPFallback = false;
        localDomain = "home.arpa";
      };
    };

  # Config F: localDomain null
  configF =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        useDHCPFallback = false;
        localDomain = null;
      };
    };

  # Config G: Zone with NTP-only inputRules (no DNS) should not get kresd listeners
  configG = {
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
      network = {
        icmpEcho = "enable";
        accessTo = [];
        inputRules = [
          {
            udp.dport = 123;
            verdict = "accept";
            comment = "NTP only";
          }
        ];
      };
    };
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns = {
      upstream = ["1.1.1.1"];
      useDHCPFallback = false;
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
      mgmt = {
        hardwareName = "eth2";
        network = {
          type = "static";
          addresses = ["10.0.20.1/24"];
          zone = "network";
        };
      };
    };
  };

  extraA = (evalConfig configA).services.kresd.extraConfig;
  extraB = (evalConfig configB).services.kresd.extraConfig;
  extraC = (evalConfig configC).services.kresd.extraConfig;
  extraD = (evalConfig configD).services.kresd.extraConfig;
  extraE = (evalConfig configE).services.kresd.extraConfig;
  extraF = (evalConfig configF).services.kresd.extraConfig;

  evalB = evalConfig configB;
  evalG = evalConfig configG;

  tests = [
    # Config A: Simple upstream, no fallback
    (assertTrue "A: has policy.FORWARD"
      (contains "policy.FORWARD" extraA))

    (assertTrue "A: has upstream server"
      (contains "'1.1.1.1'" extraA))

    (assertTrue "A: no get_fallback function"
      (notContains "get_fallback" extraA))

    (assertTrue "A: no get_dhcp_dns function"
      (notContains "get_dhcp_dns" extraA))

    # Config B: Upstream with DHCP fallback
    (assertTrue "B: has get_fallback"
      (contains "get_fallback" extraB))

    (assertTrue "B: has dhcp-dns file path"
      (contains "/run/kresd/dhcp-dns" extraB))

    (assertTrue "B: kresd-dhcp-dns service exists"
      (builtins.hasAttr "kresd-dhcp-dns" evalB.systemd.services))

    # Config C: Upstream with static fallback
    (assertTrue "C: has get_fallback"
      (contains "get_fallback" extraC))

    (assertTrue "C: has fallback server"
      (contains "'8.8.8.8'" extraC))

    # Config D: DNSSEC disabled
    (assertTrue "D: has trust_anchors.negative"
      (contains "trust_anchors.negative" extraD))

    # Config E: localDomain set
    (assertTrue "E: has policy.suffix DENY"
      (contains "policy.suffix(policy.DENY" extraE))

    (assertTrue "E: has home.arpa domain"
      (contains "home.arpa" extraE))

    # Config F: localDomain null
    (assertTrue "F: no policy.suffix DENY"
      (notContains "policy.suffix(policy.DENY" extraF))

    # Config G: NTP-only zone should not get kresd listeners
    (assertTrue "G: kresd does not listen on NTP-only zone interface"
      (let
        listenAddrs = evalG.services.kresd.listenPlain;
        # mgmt interface has 10.0.20.1 — should NOT be in listen list
      in
        !lib.any (addr: lib.hasPrefix "10.0.20.1" addr) listenAddrs))

    (assertTrue "G: kresd still listens on DNS-serving zone interface"
      (let
        listenAddrs = evalG.services.kresd.listenPlain;
        # lan interface has 10.0.10.1 — should be in listen list
      in
        lib.any (addr: lib.hasPrefix "10.0.10.1" addr) listenAddrs))
  ];

  allPass = lib.all (x: x) tests;
in
  if allPass
  then
    pkgs.runCommand "router6-kresd-config" {} ''
      echo "All ${toString (builtins.length tests)} kresd config tests passed"
      echo "PASS" > $out
    ''
  else throw "kresd config tests failed"
