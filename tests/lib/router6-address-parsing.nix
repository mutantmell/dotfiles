# Address parsing property tests for router6
#
# Pure Nix evaluation tests verifying that parseCIDR and parseIPAddress
# correctly drive systemd-networkd addresses, Kea subnets, kresd listeners,
# and RA prefixes.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-address-parsing.nix
# Or:  nix build .#checks.x86_64-linux.router6-address-parsing
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

  contains = needle: haystack: builtins.match ".*${lib.escapeRegex needle}.*" haystack != null;

  # Config with known addresses for both v4 and v6
  cfg = evalConfig {
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    dns.upstream = ["9.9.9.9"];
    dns.useDHCPFallback = false;
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
          addresses = ["10.0.20.1/24" "fdc6:55f2:0a5e:14::1/64"];
          zone = "trusted";
          dhcp.enable = true;
          dhcp6 = {
            enable = true;
            mode = "stateful";
          };
          subnetId = 20;
        };
      };
    };
  };

  networkd = cfg.systemd.network.networks;
  lanNet = networkd."10-lan";
  keaSubnets4 = cfg.services.kea.dhcp4.settings.subnet4;
  keaSubnets6 = cfg.services.kea.dhcp6.settings.subnet6;
  kresd = cfg.services.kresd.listenPlain;
  inherit (cfg.networking.nftables) ruleset;

  # Find the Kea subnet for our known network
  keaLan4 = builtins.head (builtins.filter (s: s.subnet == "10.0.20.0/24") keaSubnets4);
  keaLan6 = builtins.head (builtins.filter (s: s.subnet == "fdc6:55f2:0a5e:14::/64") keaSubnets6);

  tests = {
    # --- parseCIDR → systemd-networkd (CIDR strings preserved) ---
    "systemd-networkd: v4 address is CIDR" =
      assertTrue "v4 CIDR" (builtins.elem "10.0.20.1/24" lanNet.address);

    "systemd-networkd: v6 address is CIDR" =
      assertTrue "v6 CIDR" (builtins.elem "fdc6:55f2:0a5e:14::1/64" lanNet.address);

    # --- parseCIDR → RA prefix (networkPrefix extraction) ---
    "RA prefix: extracted from v6 address" = let
      prefixes = map (p: p.Prefix) lanNet.ipv6Prefixes;
    in
      assertTrue "RA prefix" (builtins.elem "fdc6:55f2:0a5e:14::/64" prefixes);

    # --- parseCIDR → Kea DHCPv4 (networkAddr, poolStart, poolEnd, gateway) ---
    "kea4: subnet derived from networkAddr" =
      assertEq "kea4 subnet" keaLan4.subnet "10.0.20.0/24";

    "kea4: pool defaults from parsed octets" =
      assertEq "kea4 pool" (builtins.head keaLan4.pools).pool "10.0.20.100 - 10.0.20.200";

    "kea4: gateway is the parsed IP" = let
      routerOpt = builtins.head (builtins.filter (o: o.name == "routers") keaLan4.option-data);
    in
      assertEq "kea4 gateway" routerOpt.data "10.0.20.1";

    # --- parseCIDR → Kea DHCPv6 (networkPrefix extraction) ---
    "kea6: subnet uses networkPrefix" =
      assertEq "kea6 subnet" keaLan6.subnet "fdc6:55f2:0a5e:14::/64";

    "kea6: pool uses networkPrefix" =
      assertEq "kea6 pool" (builtins.head keaLan6.pools).pool "fdc6:55f2:0a5e:14::1000-fdc6:55f2:0a5e:14::1fff";

    "kea6: dns-servers is the parsed IP" = let
      dnsOpt = builtins.head (builtins.filter (o: o.name == "dns-servers") keaLan6.option-data);
    in
      assertEq "kea6 dns" dnsOpt.data "fdc6:55f2:0a5e:14::1";

    # --- parseCIDR → kresd (ip extraction) ---
    "kresd: listens on parsed v4 IP" =
      assertTrue "kresd v4" (builtins.elem "10.0.20.1:53" kresd);

    "kresd: listens on parsed v6 IP" =
      assertTrue "kresd v6" (builtins.elem "[fdc6:55f2:0a5e:14::1]:53" kresd);

    # --- parseCIDR → Kea DHCPv4 stable subnet ID (ipv4ToInt on networkAddr) ---
    "kea4: stable subnet ID derived from network address" = let
      # 10.0.20.0 → 10*2^24 + 0*2^16 + 20*2^8 + 0 = 167773184 + 5120 = 167778304
      expectedId = 10 * 16777216 + 0 * 65536 + 20 * 256 + 0;
    in
      assertEq "kea4 subnet id" keaLan4.id expectedId;
  };

  failures = lib.filterAttrs (_: v: !v) tests;
  failCount = builtins.length (builtins.attrNames failures);
  passCount = builtins.length (builtins.attrNames tests);
in
  if failCount > 0
  then
    builtins.throw "router6-address-parsing: ${toString failCount} test(s) failed:\n${
      lib.concatMapStringsSep "\n" (name: "  FAIL: ${name}") (builtins.attrNames failures)
    }"
  else
    pkgs.runCommand "router6-address-parsing" {} ''
      echo "router6-address-parsing: ${toString passCount}/${toString passCount} tests passed"
      echo passed > $out
    ''
