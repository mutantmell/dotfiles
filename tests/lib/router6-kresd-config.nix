# kresd DNS config tests for router6
#
# Pure Nix evaluation tests verifying kresd Lua configuration:
# - Upstream DNS forwarding
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

  # Config A: Simple upstream
  configA =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
      };
    };

  # Config D: DNSSEC disabled
  configD =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        enableDNSSEC = false;
      };
    };

  # Config E: localDomain set
  configE =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        localDomain = "home.arpa";
      };
    };

  # Config F: localDomain null
  configF =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
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

  # Config H: Multi-address interface — kresd should listen on all addresses
  configH = {
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
    dns = {
      upstream = ["1.1.1.1"];
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
          addresses = ["10.0.10.1/24" "10.97.10.1/24"];
          zone = "trusted";
          dhcp.enable = true;
        };
      };
    };
  };

  evalH = evalConfig configH;

  # Config I: fallbackFromLease enabled
  configI =
    baseTopology
    // {
      dns = {
        upstream = ["10.0.0.1"];
        fallbackFromLease = "eth0";
      };
    };

  # Config J: fallbackFromLease + custom fallbackUpstream
  configJ =
    baseTopology
    // {
      dns = {
        upstream = ["10.0.0.1"];
        fallbackFromLease = "eth0";
        fallbackUpstream = ["1.1.1.1" "1.0.0.1"];
      };
    };

  extraA = (evalConfig configA).services.kresd.extraConfig;
  extraD = (evalConfig configD).services.kresd.extraConfig;
  extraE = (evalConfig configE).services.kresd.extraConfig;
  extraF = (evalConfig configF).services.kresd.extraConfig;

  evalG = evalConfig configG;
  evalI = evalConfig configI;
  evalJ = evalConfig configJ;
  extraI = evalI.services.kresd.extraConfig;
  extraJ = evalJ.services.kresd.extraConfig;

  tests = [
    # Config A: Simple upstream
    (assertTrue "A: has policy.FORWARD"
      (contains "policy.FORWARD" extraA))

    (assertTrue "A: has upstream server"
      (contains "'1.1.1.1'" extraA))

    (assertTrue "A: no fallback machinery"
      (notContains "get_fallback" extraA))

    (assertTrue "A: no DHCP DNS extraction"
      (notContains "get_dhcp_dns" extraA))

    (assertTrue "A: no primary_down state"
      (notContains "primary_down" extraA))

    # Config D: DNSSEC disabled — knot-resolver >=5.7 requires
    # trust_anchors.set_insecure({...}); the legacy trust_anchors.negative
    # assignment is rejected at load time.
    (assertTrue "D: has trust_anchors.set_insecure"
      (contains "trust_anchors.set_insecure" extraD))

    # Config E: localDomain set — kresd no longer emits a DENY rule for it
    # (localDomain is consumed by DHCP domain-name only). Verify kresd config
    # does not contain DENY policy machinery.
    (assertTrue "E: no policy.suffix DENY (localDomain not enforced in kresd)"
      (notContains "policy.suffix(policy.DENY" extraE))

    (assertTrue "E: no home.arpa in kresd config"
      (notContains "home.arpa" extraE))

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

    # Config H: Multi-address interface — kresd listens on all addresses
    (assertTrue "H: kresd listens on first address (10.0.10.1)"
      (let
        listenAddrs = evalH.services.kresd.listenPlain;
      in
        lib.any (addr: lib.hasPrefix "10.0.10.1" addr) listenAddrs))

    (assertTrue "H: kresd listens on second address (10.97.10.1)"
      (let
        listenAddrs = evalH.services.kresd.listenPlain;
      in
        lib.any (addr: lib.hasPrefix "10.97.10.1" addr) listenAddrs))

    # Config A baseline: no fallback machinery when fallbackFromLease unset
    (assertTrue "A: no dofile when fallback not configured"
      (notContains "dofile" extraA))

    (assertTrue "A: no fallback renderer service when fallback not configured"
      (!(evalConfig configA).systemd.services ? "kresd-isp-fallback-render"))

    # Config I: fallbackFromLease enabled — extraConfig must load runtime file
    (assertTrue "I: extraConfig loads runtime fallback file via dofile"
      (contains "dofile('/run/knot-resolver/isp-dns.lua')" extraI))

    (assertTrue "I: extraConfig forwards to primary upstream"
      (contains "'10.0.0.1'" extraI))

    # Strict-failover circuit-breaker must be present (the Phase 1 broken impl
    # concatenated primary+fallback into one FORWARD list; that design is
    # explicitly rejected here).
    (assertTrue "I: declares primary_down breaker flag"
      (contains "primary_down" extraI))

    (assertTrue "I: declares PRIMARY_THRESHOLD constant"
      (contains "PRIMARY_THRESHOLD" extraI))

    (assertTrue "I: declares PRIMARY_RETRY cooldown"
      (contains "PRIMARY_RETRY" extraI))

    (assertTrue "I: uses event-based health probe"
      (contains "event.recurrent" extraI))

    (assertTrue "I: probes via worker.resolve (named `resolve` in sandbox)"
      (contains "resolve(" extraI))

    (assertTrue "I: defines a fallback policy.FORWARD separate from primary"
      (contains "policy.FORWARD(fallback_dns)" extraI))

    (assertTrue "I: defines a primary policy.FORWARD separate from fallback"
      (contains "policy.FORWARD(primary_servers)" extraI))

    (assertTrue "I: does NOT concatenate primary + fallback into one FORWARD"
      (let
        # The broken impl built a single list `{primary..., fallback...}` and
        # handed it to policy.FORWARD. The strict-failover impl keeps them as
        # two distinct closures dispatched by the breaker.
        primaryInForward = builtins.match ".*policy.FORWARD\\(\\{'10\\.0\\.0\\.1'[^}]*fallback.*" extraI;
      in
        primaryInForward == null))

    (assertTrue "I: renderer service is defined"
      (evalI.systemd.services ? "kresd-isp-fallback-render"))

    (assertTrue "I: lease-watch path unit is defined"
      (evalI.systemd.paths ? "kresd-isp-fallback"))

    (assertTrue "I: reload service is defined"
      (evalI.systemd.services ? "kresd-isp-fallback"))

    (assertTrue "I: renderer ordered before kresd.target"
      (lib.elem "kresd.target" evalI.systemd.services."kresd-isp-fallback-render".before))

    (assertTrue "I: renderer ordered before kresd@.service instances"
      (lib.elem "kresd@.service" evalI.systemd.services."kresd-isp-fallback-render".before))

    (assertTrue "I: renderer waits for WAN online"
      (lib.elem "systemd-networkd-wait-online@eth0.service"
        evalI.systemd.services."kresd-isp-fallback-render".after))

    # Config J: custom static fallbackUpstream propagates into renderer script
    (assertTrue "J: static fallback list reaches renderer ExecStart"
      (let
        execStart = evalJ.systemd.services."kresd-isp-fallback-render".serviceConfig.ExecStart;
        scriptPath = toString execStart;
        scriptText = builtins.readFile scriptPath;
      in
        contains "1.1.1.1" scriptText
        && contains "1.0.0.1" scriptText))

    (assertTrue "I: default fallback (Quad9) reaches renderer ExecStart"
      (let
        execStart = evalI.systemd.services."kresd-isp-fallback-render".serviceConfig.ExecStart;
        scriptPath = toString execStart;
        scriptText = builtins.readFile scriptPath;
      in
        contains "9.9.9.9" scriptText
        && contains "149.112.112.112" scriptText))
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
