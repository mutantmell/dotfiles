# Snapshot test for thebeyond router nftables ruleset
#
# TEMPORARY: Pre-deployment validation. Remove after thebeyond is successfully
# deployed and the config is confirmed working on physical hardware. The generic
# router6-firewall-snapshot test provides ongoing coverage of the module.
#
# Evaluates the actual thebeyond router6 config (with hardware stubs) and
# compares the generated nftables ruleset against a golden file. This catches
# rule generation bugs, missing/malformed rules, and unintended changes.
#
# Run: nix build .#checks.x86_64-linux.thebeyond-firewall-snapshot
#
# To update the golden file after an intentional change:
#   nix-instantiate --eval --strict tests/lib/thebeyond-firewall-snapshot.nix --arg updateGolden true 2>&1 | \
#     sed 's/^"//' | sed 's/"$//' | sed 's/\\n/\n/g' | sed 's/\\"/"/g' > tests/lib/expected-thebeyond-firewall.nft

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, updateGolden ? false
}:

let
  # Hardcoded IP addresses from network registry (lib/common/data/network.nix)
  # These match the actual values used in hosts/thebeyond/default.nix
  # Primary (10.97) and legacy (10.0) addresses for dual-stack migration
  host      = { ipv4 = "10.97.11.1"; ipv4Legacy = "10.0.11.1"; ipv6 = "fdc6:55f2:0a5e:b::1"; };
  phantasma = { ipv4 = "10.97.11.2"; ipv4Legacy = "10.0.11.2"; ipv6 = "fdc6:55f2:0a5e:b::2"; };
  ordis     = { ipv4 = "10.97.100.40"; ipv4Legacy = "10.0.100.40"; ipv6 = "fdc6:55f2:0a5e:64::28"; };
  roer      = { ipv4 = "10.97.11.3"; ipv4Legacy = "10.0.11.3"; ipv6 = "fdc6:55f2:0a5e:b::3"; };
  legram    = { ipv4 = "10.97.11.4"; ipv4Legacy = "10.0.11.4"; ipv6 = "fdc6:55f2:0a5e:b::4"; };
  ymir      = { ipv4 = "10.97.11.5"; ipv4Legacy = "10.0.11.5"; ipv6 = "fdc6:55f2:0a5e:b::5"; };

  # Per-VLAN bridge helper (same pattern as hosts/thebeyond/default.nix)
  mkVlanBridge = { name, tag, addresses, zone, enableDhcp ? true, enableDhcp6 ? true }: {
    bond0Vlans."v${name}.bond0" = { inherit tag; network.type = "disabled"; };
    bat0Vlans."v${name}.bat0" = { inherit tag; network.type = "disabled"; };
    bridges."br${name}" = {
      kind = "bridge";
      members = [ "v${name}.bond0" "v${name}.bat0" ];
      network = {
        type = "static";
        inherit addresses zone;
        subnetId = tag;
        dhcp.enable = enableDhcp;
        dhcp6.enable = enableDhcp6;
      };
    };
  };

  vlanDefs = [
    (mkVlanBridge { name = "MGMT";  tag = 10;  zone = "network";    addresses = [ "10.0.10.1/24" "10.97.10.1/24" ]; enableDhcp = false; })
    (mkVlanBridge { name = "INFRA"; tag = 11;  zone = "management"; addresses = [ "10.0.11.1/24" "10.97.11.1/24" ]; })
    (mkVlanBridge { name = "HOME";  tag = 20;  zone = "trusted";    addresses = [ "10.0.20.1/24" "10.97.20.1/24" ]; })
    (mkVlanBridge { name = "GUEST"; tag = 30;  zone = "untrusted";  addresses = [ "10.0.30.1/24" "10.97.30.1/24" ]; })
    (mkVlanBridge { name = "ADU";   tag = 31;  zone = "untrusted";  addresses = [ "10.0.31.1/24" "10.97.31.1/24" ]; })
    (mkVlanBridge { name = "IOT";   tag = 40;  zone = "untrusted";  addresses = [ "10.0.40.1/24" "10.97.40.1/24" ]; })
    (mkVlanBridge { name = "GAME";  tag = 41;  zone = "untrusted";  addresses = [ "10.0.41.1/24" "10.97.41.1/24" ]; })
    (mkVlanBridge { name = "DMZ";   tag = 100; zone = "untrusted";  addresses = [ "10.0.100.1/24" "10.97.100.1/24" ]; })
  ];

  allBond0Vlans = lib.foldl' (a: b: a // b.bond0Vlans) {} vlanDefs;
  allBat0Vlans  = lib.foldl' (a: b: a // b.bat0Vlans) {} vlanDefs;
  allBridges    = lib.foldl' (a: b: a // b.bridges) {} vlanDefs;

  eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ../../modules/router6
      {
        # Hardware stubs (no disko, impermanence, sops, microvm, home-manager)
        boot.loader.grub.device = "nodev";
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        nixpkgs.hostPlatform = "x86_64-linux";
        system.stateVersion = "25.11";

        # ================================================================
        # Exact thebeyond router6 config (from hosts/thebeyond/default.nix)
        # with hardware-specific values (MAC, sops) replaced by stubs
        # ================================================================
        router6 = {
          enable = true;
          ulaPrefix = "fdc6:55f2:0a5e::/48";

          zones = {
            external = {
              icmpEcho = "disable";
              accessTo = [];
              inputRules = [];
            };

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
              inputRules = [
                { verdict = "accept"; comment = "Full router service access"; }
              ];
            };

            trusted = {
              icmpEcho = "enable";
              accessTo = [ "management" "trusted" "untrusted" "external" ];
              inputRules = [
                { verdict = "accept"; comment = "Full router service access"; }
              ];
            };

            untrusted = {
              icmpEcho = "enable";
              accessTo = [ "external" ];
              inputRules = [
                { udp.dport = [ 53 67 547 ]; verdict = "accept"; comment = "DNS + DHCP"; }
                { tcp.dport = 53; verdict = "accept"; comment = "DNS over TCP"; }
              ];
            };

            isolated = {
              icmpEcho = "disable";
              accessTo = [];
              inputRules = [];
            };
          };

          dns = {
            upstream = [ phantasma.ipv4 ];
            useDHCPFallback = true;
            localDomain = "internal";
          };

          firewall = {
            extraForwardRules = [
              { iifname = "brDMZ"; oifname = "wg-ba"; verdict = "accept"; }
              { iifname = "wg-ba"; ip.daddr = ordis.ipv4; verdict = "accept"; }
              { iifname = "wg-ba"; ip6.daddr = ordis.ipv6; verdict = "accept"; }
              # ordis -> roer (OIDC token exchange)
              { iifname = "brDMZ"; oifname = "brINFRA";
                ip.saddr = ordis.ipv4; ip.daddr = roer.ipv4;
                tcp.dport = 443; verdict = "accept"; comment = "ordis -> roer (OIDC)"; }
              { iifname = "brDMZ"; oifname = "brINFRA";
                ip6.saddr = ordis.ipv6; ip6.daddr = roer.ipv6;
                tcp.dport = 443; verdict = "accept"; comment = "ordis -> roer (OIDC v6)"; }
              # vDMZ -> legram (ACME certificate issuance)
              { iifname = "brDMZ"; oifname = "brINFRA";
                ip.daddr = legram.ipv4; tcp.dport = 443;
                verdict = "accept"; comment = "vDMZ -> legram (ACME)"; }
              { iifname = "brDMZ"; oifname = "brINFRA";
                ip6.daddr = legram.ipv6; tcp.dport = 443;
                verdict = "accept"; comment = "vDMZ -> legram (ACME v6)"; }
              # vDMZ -> ymir (Loki log push)
              { iifname = "brDMZ"; oifname = "brINFRA";
                ip.daddr = ymir.ipv4; tcp.dport = 3100;
                verdict = "accept"; comment = "vDMZ -> ymir (Loki)"; }
              { iifname = "brDMZ"; oifname = "brINFRA";
                ip6.daddr = ymir.ipv6; tcp.dport = 3100;
                verdict = "accept"; comment = "vDMZ -> ymir (Loki v6)"; }
            ];

            portForwards = [
              {
                proto = "tcp";
                sourcePort = 22;
                destination = "${ordis.ipv4}:22";
                sourceInterface = "wg-ba";
              }
            ];

            extraNatPostroutingRules = [
              # Wireguard BA tunnel masquerading
              { oifname = "wg-ba"; masquerade = true; }
              { iifname = "wg-ba"; ip.daddr = ordis.ipv4; masquerade = true; }
            ];

            extraNatRules = [
              # DNS interception - redirect bypass attempts to router's DNS
              # Includes both 10.97 and legacy 10.0 addresses during migration
              {
                ip.saddr = { not = [ phantasma.ipv4 phantasma.ipv4Legacy ]; };
                ip.daddr = { not = [ host.ipv4 host.ipv4Legacy phantasma.ipv4 phantasma.ipv4Legacy ]; };
                udp.dport = 53;
                verdict = { dnat = "${host.ipv4Legacy}:53"; };
                comment = "Intercept DNS bypass (UDP)";
              }
              {
                ip.saddr = { not = [ phantasma.ipv4 phantasma.ipv4Legacy ]; };
                ip.daddr = { not = [ host.ipv4 host.ipv4Legacy phantasma.ipv4 phantasma.ipv4Legacy ]; };
                tcp.dport = 53;
                verdict = { dnat = "${host.ipv4Legacy}:53"; };
                comment = "Intercept DNS bypass (TCP)";
              }
            ];

            extraNat6Rules = [
              {
                ip6.saddr = { not = phantasma.ipv6; };
                ip6.daddr = { not = [ host.ipv6 phantasma.ipv6 ]; };
                udp.dport = 53;
                verdict = { dnat = "[${host.ipv6}]:53"; };
                comment = "Intercept IPv6 DNS bypass (UDP)";
              }
              {
                ip6.saddr = { not = phantasma.ipv6; };
                ip6.daddr = { not = [ host.ipv6 phantasma.ipv6 ]; };
                tcp.dport = 53;
                verdict = { dnat = "[${host.ipv6}]:53"; };
                comment = "Intercept IPv6 DNS bypass (TCP)";
              }
            ];
          };

          topology = {
            # WAN interface
            wan = {
              hardwareName = "wan";
              network = {
                type = "dhcp";
                zone = "external";
                nat.enable = true;
                defaultRoute = true;
              };
            };

            # LAN interfaces (bonded)
            lan = { hardwareName = "lan"; };
            opt1 = { hardwareName = "opt1"; };

            # Bond combining lan + opt1
            bond0 = {
              kind = "bond";
              mode = "802.3ad";
              lacpTransmitRate = "fast";
              miiMonitorSec = "100ms";
              members = ["lan" "opt1"];
              network = {
                type = "disabled";
                mtu = 1536;
              };
              vlans = allBond0Vlans;
            };

            # Batman-adv mesh device
            bat0 = {
              kind = "batman";
              members = ["bond0"];
              batman = {
                gatewayMode = "off";
                routingAlgorithm = "batman-v";
              };
              network.type = "disabled";
              vlans = allBat0Vlans;
            };

            # Spare interface
            opt2 = { hardwareName = "opt2"; };

            # Wireguard - BA tunnel (isolated/lockdown)
            "wg-ba" = {
              kind = "wireguard";
              network = {
                type = "static";
                addresses = [
                  "10.100.0.1/24"
                  "fdc6:55f2:0a5e:6400::1/64"
                ];
                zone = "isolated";
                required = false;
              };
              wireguard = {
                privateKeyFile = "/run/secrets/dummy-wg-key";
                port = 38506;
                openFirewall = true;
                peers = [{
                  publicKey = "O+WWPlhy6Lg9YT3hYqq+/8gZ48PpRXaUTl4eFFwgTVA=";
                  allowedIPs = [ "10.100.0.3/32" "fdc6:55f2:0a5e:6400::3/128" ];
                  persistentKeepalive = 25;
                }];
              };
            };

            # Wireguard - VPN for mobile devices
            "wg-vpn" = {
              kind = "wireguard";
              network = {
                type = "static";
                addresses = [
                  "10.100.10.1/24"
                  "fdc6:55f2:0a5e:640a::1/64"
                ];
                zone = "trusted";
                required = false;
              };
              wireguard = {
                privateKeyFile = "/run/secrets/dummy-wg-key";
                port = 59362;
                openFirewall = true;
                peers = [
                  {
                    publicKey = "sqPuQAWAKJzTice+L2kedo9X7Hx5WsMT/A6QXJVL/nA=";
                    allowedIPs = [ "10.100.10.20/32" "fdc6:55f2:0a5e:640a::14/128" ];
                  }
                  {
                    publicKey = "8g4r9czA23tS/XTOajuIa/BNfDE2x4GwdXXi+udE6gY=";
                    allowedIPs = [ "10.100.10.21/32" "fdc6:55f2:0a5e:640a::15/128" ];
                  }
                ];
              };
            };
          } // allBridges;
        };
      }
    ];
  };

  ruleset = eval.config.networking.nftables.ruleset;

in
  if updateGolden then ruleset
  else let
    expected = builtins.readFile ./expected-thebeyond-firewall.nft;
    pass = ruleset == expected;
  in
    if pass then
      pkgs.runCommand "thebeyond-firewall-snapshot" {} ''
        echo "PASS: thebeyond nftables ruleset matches golden file"
        echo "PASS" > $out
      ''
    else
      pkgs.runCommand "thebeyond-firewall-snapshot" {
        inherit ruleset expected;
        passAsFile = [ "ruleset" "expected" ];
      } ''
        echo "FAIL: thebeyond nftables ruleset does not match golden file"
        echo ""
        echo "=== DIFF (expected vs actual) ==="
        diff --color=auto "$expectedPath" "$rulesetPath" || true
        echo ""
        echo "To update the golden file, run:"
        echo "  nix-instantiate --eval --strict tests/lib/thebeyond-firewall-snapshot.nix --arg updateGolden true 2>&1 | \\"
        echo "    sed 's/^\"//' | sed 's/\"$//' | sed 's/\\\\n/\\n/g' | sed 's/\\\\\"/\"/g' > tests/lib/expected-thebeyond-firewall.nft"
        exit 1
      ''
