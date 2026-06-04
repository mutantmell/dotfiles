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

  # Config I: fallbackFromLease enabled (defaults: forward on both paths)
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

  # Config K: simple primary with explicit upstreamPolicy = "stub". Used to
  # verify the policy plumbing — single-primary branch must template the
  # option, not hardcode FORWARD/STUB.
  configK =
    baseTopology
    // {
      dns = {
        upstream = ["1.1.1.1"];
        upstreamPolicy = "stub";
      };
    };

  # Config L: primary + fallback with upstreamPolicy = "stub". Covers the
  # strict-failover branch's policy templating.
  configL =
    baseTopology
    // {
      dns = {
        upstream = ["10.0.0.1"];
        upstreamPolicy = "stub";
        fallbackFromLease = "eth0";
      };
    };

  # Config M: source routes (GUEST VLAN ad-block bypass) layered on the
  # strict-failover dispatcher. Verifies per-CIDR overrides emit view.rule_src
  # policy rules ahead of the dispatcher.
  configM =
    baseTopology
    // {
      dns = {
        upstream = ["10.0.0.1"];
        upstreamPolicy = "stub";
        fallbackFromLease = "eth0";
        sourceRoutes = [
          {
            cidr = "10.0.30.0/24";
            upstream = ["10.0.10.10@5335"];
          }
          {
            cidr = "fdc6:55f2:0a5e:1e::/64";
            upstream = ["[fdc6:55f2:0a5e:a::a]@5335"];
          }
        ];
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
  # Config N: sourceRoutes WITHOUT a fallback. The route is static — no
  # breaker, so its action must not reference primary_down/fallback.
  configN =
    baseTopology
    // {
      dns = {
        upstream = ["10.0.0.1"];
        upstreamPolicy = "stub";
        sourceRoutes = [
          {
            cidr = "10.0.30.0/24";
            upstream = ["10.0.10.10@5335"];
          }
        ];
      };
    };

  extraK = (evalConfig configK).services.kresd.extraConfig;
  extraL = (evalConfig configL).services.kresd.extraConfig;
  extraM = (evalConfig configM).services.kresd.extraConfig;
  extraN = (evalConfig configN).services.kresd.extraConfig;

  tests = [
    # Config A: Simple upstream — module default is upstreamPolicy = "forward",
    # so the single-primary path must template to policy.FORWARD (and NOT
    # policy.STUB).
    (assertTrue "A: has policy.FORWARD on the primary path"
      (contains "policy.FORWARD" extraA))

    (assertTrue "A: does not use policy.STUB on default config"
      (notContains "policy.STUB" extraA))

    (assertTrue "A: has upstream server"
      (contains "'1.1.1.1'" extraA))

    # Config K: explicit upstreamPolicy = "stub" — single-primary branch must
    # template the option through to policy.STUB. Defends against
    # re-introducing a hardcoded primaryPolicyFn.
    (assertTrue "K: has policy.STUB when upstreamPolicy = stub"
      (contains "policy.STUB" extraK))

    (assertTrue "K: does NOT emit policy.FORWARD when upstreamPolicy = stub"
      (notContains "policy.FORWARD" extraK))

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

    (assertTrue "D: does not pin a static root anchor when DNSSEC is off"
      (notContains "trust_anchors.add_file" extraD))

    # Config A defaults to enableDNSSEC = true. Verify the symmetric
    # DNSSEC-on branch: pinned static root KSK in readonly mode, no
    # set_insecure.
    (assertTrue "A: pins static root KSK via trust_anchors.add_file"
      (contains "trust_anchors.add_file" extraA))

    (assertTrue "A: pins KSK from dns-root-data root.key"
      (contains "/root.key" extraA))

    (assertTrue "A: loads the pinned anchor in readonly mode"
      # match `add_file('<any path ending in root.key>', true)` without
      # referring to the dns-root-data store path (refs are disallowed in
      # pure-eval test outputs).
      (builtins.match ".*add_file\\('[^']*root\\.key', true\\).*" extraA != null))

    (assertTrue "A: does not disable the root TA when DNSSEC is enabled"
      # Match the actual call, not the word in a comment.
      (notContains "trust_anchors.set_insecure" extraA))

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

    # Config I: defaults — both upstream and fallback use FORWARD. Verifies
    # the strict-failover dispatcher templates both policies from options
    # rather than hardcoding either side.
    (assertTrue "I: primary uses policy.FORWARD (default upstreamPolicy)"
      (contains "policy.FORWARD(primary_servers)" extraI))

    (assertTrue "I: fallback uses policy.FORWARD (default fallbackPolicy)"
      (contains "policy.FORWARD(fallback_dns)" extraI))

    (assertTrue "I: does NOT emit policy.STUB on default config"
      (notContains "policy.STUB" extraI))

    (assertTrue "I: does NOT concatenate primary + fallback into one upstream list"
      (let
        # The broken impl built a single list `{primary..., fallback...}` and
        # handed it to policy.FORWARD. The strict-failover impl keeps them as
        # two distinct closures dispatched by the breaker.
        primaryInForward = builtins.match ".*policy\\.(FORWARD|STUB)\\(\\{'10\\.0\\.0\\.1'[^}]*fallback.*" extraI;
      in
        primaryInForward == null))

    # Config L: explicit upstreamPolicy = "stub" with fallback path. Verifies
    # the strict-failover dispatcher uses STUB on primary and keeps FORWARD
    # on fallback (the load-bearing combination for the thebeyond deployment).
    (assertTrue "L: primary uses policy.STUB when upstreamPolicy = stub"
      (contains "policy.STUB(primary_servers)" extraL))

    (assertTrue "L: fallback still uses policy.FORWARD (default fallbackPolicy)"
      (contains "policy.FORWARD(fallback_dns)" extraL))

    (assertTrue "L: primary does NOT use policy.FORWARD with upstreamPolicy = stub"
      (let
        m = builtins.match ".*policy\\.FORWARD\\(primary_servers.*" extraL;
      in
        m == null))

    (assertTrue "I: renderer service is defined"
      (evalI.systemd.services ? "kresd-isp-fallback-render"))

    (assertTrue "I: lease-watch path unit is defined"
      (evalI.systemd.paths ? "kresd-isp-fallback"))

    (assertTrue "I: reload service is defined"
      (evalI.systemd.services ? "kresd-isp-fallback"))

    (assertTrue "I: renderer ordered before kresd.target"
      (lib.elem "kresd.target" evalI.systemd.services."kresd-isp-fallback-render".before))

    # Template-level Before= does not propagate to instances, so the
    # ordering for kresd@.service instances is wired in the other
    # direction via kresd@ template's After= + Requires=.
    (assertTrue "I: kresd@.service ordered after renderer"
      (lib.elem "kresd-isp-fallback-render.service"
        evalI.systemd.services."kresd@".after))

    (assertTrue "I: kresd@.service requires renderer (hard dependency)"
      (lib.elem "kresd-isp-fallback-render.service"
        evalI.systemd.services."kresd@".requires))

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

    # Config A baseline: no sourceRoutes → no view module, no source-route rules
    (assertTrue "A: does not load view module when no sourceRoutes"
      (notContains "modules.load('view')" extraA))

    (assertTrue "A: emits no view.rule_src without sourceRoutes"
      (notContains "view.rule_src" extraA))

    # Config M: sourceRoutes present (with fallback) — must load view, hoist
    # the no-block action with the configured upstreamPolicy (STUB here), and
    # register a breaker-aware view.rule_src per route.
    (assertTrue "M: loads the view module"
      (contains "modules.load('view')" extraM))

    (assertTrue "M: hoists the v4 no-block action with upstreamPolicy"
      (contains "local sr_noblock_1 = policy.STUB({'10.0.10.10@5335'})" extraM))

    (assertTrue "M: hoists the v6 no-block action with upstreamPolicy"
      (contains "local sr_noblock_2 = policy.STUB({'[fdc6:55f2:0a5e:a::a]@5335'})" extraM))

    (assertTrue "M: registers a view.rule_src rule for the v4 source CIDR"
      (contains "view.rule_src(function (state, req) if primary_down then return fallback(state, req) end return sr_noblock_1(state, req) end, '10.0.30.0/24')" extraM))

    (assertTrue "M: registers a view.rule_src rule for the v6 source CIDR"
      (contains "view.rule_src(function (state, req) if primary_down then return fallback(state, req) end return sr_noblock_2(state, req) end, 'fdc6:55f2:0a5e:1e::/64')" extraM))

    (assertTrue "M: wraps source routes in policy.add"
      (contains "policy.add(view.rule_src" extraM))

    # The breaker-aware route must fail over to the SAME ISP fallback when the
    # primary breaker trips — that is the VLAN-outage guarantee.
    (assertTrue "M: source route falls back to ISP on primary_down"
      (contains "if primary_down then return fallback(state, req) end" extraM))

    # Source routes must be registered BEFORE the dispatcher's policy.add so a
    # match short-circuits the default forward chain (first-match-wins). The
    # text preceding the dispatcher's load marker must already hold the rules.
    (assertTrue "M: source-route rules precede the strict-failover dispatcher"
      (let
        beforeDispatcher = lib.head (lib.splitString "strict-failover dispatcher loaded" extraM);
      in
        contains "view.rule_src" beforeDispatcher))

    # The breaker state the source route reads must be defined BEFORE the route
    # (Lua upvalue capture); `local primary_down` precedes the rule text.
    (assertTrue "M: breaker state precedes the source-route rules"
      (let
        beforeRule = lib.head (lib.splitString "view.rule_src" extraM);
      in
        contains "local primary_down" beforeRule))

    # Config N: sourceRoutes without fallback — static route, no breaker. The
    # action is the bare hoisted local; it must NOT reference the breaker.
    (assertTrue "N: hoists the no-block action"
      (contains "local sr_noblock_1 = policy.STUB({'10.0.10.10@5335'})" extraN))

    (assertTrue "N: registers a plain view.rule_src (no breaker wrap)"
      (contains "policy.add(view.rule_src(sr_noblock_1, '10.0.30.0/24'))" extraN))

    (assertTrue "N: static source route does not reference the breaker"
      (notContains "primary_down" extraN))
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
