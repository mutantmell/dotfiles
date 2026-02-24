# Snapshot test for router6 nftables ruleset generation
#
# Evaluates a router6 config and compares the generated nftables ruleset
# against a golden file. This ensures refactors produce identical output.
#
# Run: nix-instantiate --eval --strict tests/lib/router6-firewall-snapshot.nix
# Or:  nix build .#checks.x86_64-linux.router6-firewall-snapshot
#
# To update the golden file after an intentional change:
#   nix-instantiate --eval --strict tests/lib/router6-firewall-snapshot.nix --arg updateGolden true 2>&1 | \
#     sed 's/^"//' | sed 's/"$//' | sed 's/\\n/\n/g' | sed 's/\\"/"/g' > tests/lib/expected-firewall-ruleset.nft

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, updateGolden ? false
}:

let
  # Evaluate a minimal router6 config matching the multi-zone test topology
  eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ../../modules/router6
      {
        # Minimal system config to satisfy NixOS module requirements
        boot.loader.grub.device = "nodev";
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "25.11";

        router6 = {
          enable = true;
          ulaPrefix = "fdc6:55f2:0a5e::/48";
          dns.upstream = [ "1.1.1.1" ];
          dns.useDHCPFallback = false;
          dns.localDomain = "test.local";

          zones = {
            external = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
            network = {
              icmpEcho = "enable";
              accessTo = [];
              inputRules = [
                { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
              ];
            };
            management = {
              icmpEcho = "enable";
              accessTo = [ "management" "trusted" "untrusted" ];
              forwardRules.external = [
                { udp.dport = 53; verdict = "accept"; comment = "DNS recursive queries"; }
                { tcp.dport = 53; verdict = "accept"; comment = "DNS recursive queries (TCP)"; }
                { tcp.dport = 80; verdict = "accept"; comment = "HTTP for package mirrors"; }
                { tcp.dport = 443; verdict = "accept"; comment = "HTTPS for updates"; }
                { udp.dport = 123; verdict = "accept"; comment = "NTP"; }
              ];
              inputRules = [{ verdict = "accept"; }];
            };
            trusted = {
              icmpEcho = "enable";
              accessTo = [ "management" "trusted" "untrusted" "external" ];
              inputRules = [{ verdict = "accept"; }];
            };
            untrusted = {
              icmpEcho = "enable";
              accessTo = [ "external" ];
              inputRules = [
                { udp.dport = [ 53 67 547 ]; verdict = "accept"; }
                { tcp.dport = 53; verdict = "accept"; }
              ];
            };
            isolated = { icmpEcho = "disable"; accessTo = []; inputRules = []; };
          };

          topology = {
            eth1 = {
              hardwareName = "eth1";
              network = {
                type = "static";
                addresses = [ "203.0.113.1/24" ];
                zone = "external";
                nat.enable = true;
              };
            };
            eth2 = {
              hardwareName = "eth2";
              network = {
                type = "static";
                addresses = [ "10.0.10.1/24" ];
                zone = "management";
                dhcp.enable = true;
              };
            };
            eth3 = {
              hardwareName = "eth3";
              network = {
                type = "static";
                addresses = [ "10.0.20.1/24" ];
                zone = "trusted";
                dhcp.enable = true;
              };
            };
            eth4 = {
              hardwareName = "eth4";
              network = {
                type = "static";
                addresses = [ "10.0.30.1/24" ];
                zone = "untrusted";
                dhcp.enable = true;
              };
            };
            eth5 = {
              hardwareName = "eth5";
              network = {
                type = "static";
                addresses = [ "10.0.40.1/24" ];
                zone = "isolated";
              };
            };
            eth6 = {
              hardwareName = "eth6";
              network = {
                type = "static";
                addresses = [ "10.0.50.1/24" ];
                zone = "network";
              };
            };
          };
        };
      }
    ];
  };

  ruleset = eval.config.networking.nftables.ruleset;

in
  if updateGolden then ruleset
  else let
    expected = builtins.readFile ./expected-firewall-ruleset.nft;
    pass = ruleset == expected;
  in
    if pass then
      pkgs.runCommand "router6-firewall-snapshot" {} ''
        echo "PASS: nftables ruleset matches golden file"
        echo "PASS" > $out
      ''
    else
      pkgs.runCommand "router6-firewall-snapshot" {
        inherit ruleset expected;
        passAsFile = [ "ruleset" "expected" ];
      } ''
        echo "FAIL: nftables ruleset does not match golden file"
        echo ""
        echo "=== DIFF (expected vs actual) ==="
        diff --color=auto "$expectedPath" "$rulesetPath" || true
        echo ""
        echo "To update the golden file, run:"
        echo "  nix-instantiate --eval --strict tests/lib/router6-firewall-snapshot.nix --arg updateGolden true 2>&1 > /dev/null"
        exit 1
      ''
