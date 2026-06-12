# NixOS integration test for router6 firewall zone behavior
#
# Comprehensive multi-zone test with all current trust levels represented.
# Verifies input chain (router access) and forward chain (inter-zone traffic).
#
# Tests:
# Input chain:
#  1. management → router: full access
#  2. trusted → router: full access
#  3. untrusted → router: DNS/DHCP only
#  4. isolated → router: nothing (not even DNS/DHCP)
#  5. external → router: stealth (nothing)
#  6. ICMP echo: internal only (mgmt/trusted/untrusted/network can ping, external/isolated cannot)
#
# Forward chain:
#  7.  management → trusted: allowed
#  8.  management → untrusted: allowed
#  9.  management → external: allowed (forwardRules: HTTP/S, DNS, NTP)
# 10.  trusted → management: allowed
# 11.  trusted → untrusted: allowed
# 12.  trusted → external: allowed (NAT)
# 13.  untrusted → external: allowed (NAT)
# 14.  untrusted → management: blocked
# 15.  untrusted → trusted: blocked
# 16.  isolated → anything: blocked
# 17.  external → internal: blocked
# 18.  network → router: NTP only
# 19.  network → router: DNS blocked
# 20.  network → router: SSH blocked
# 21.  network → any: no forwarding
# 22.  management → external: forwardRules (HTTP/S allowed, SSH blocked)
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
  useContainers ? false,
}: let
  machinesAttr =
    if useContainers
    then "containers"
    else "nodes";
  testRunner =
    if useContainers
    then
      args:
        (import (pkgs.path + "/nixos/lib/testing/default.nix") {inherit lib;}).runTest (args
          // {
            imports = (args.imports or []) ++ [{hostPkgs = pkgs;}];
            node.pkgs = pkgs;
            containerDefaults = {config, ...}: {
              system.name = "m${toString config.virtualisation.test.nodeNumber}";
              networking.useHostResolvConf = false;
            };
            requiredFeatures = (args.requiredFeatures or {}) // {kvm = lib.mkForce false;};
          })
    else pkgs.testers.nixosTest;
in
  testRunner {
    name = "router6-firewall-zones${lib.optionalString useContainers "-container"}";

    ${machinesAttr} = {
      router = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [
          ../../modules/router6
          ../lib/test-minimal-base.nix
        ];

        # Virtual network setup:
        # eth1 (vlan1) = WAN/external (203.0.113.0/24)
        # eth2 (vlan2) = management  (10.0.10.0/24)
        # eth3 (vlan3) = trusted     (10.0.20.0/24)
        # eth4 (vlan4) = untrusted   (10.0.30.0/24)
        # eth5 (vlan5) = isolated    (10.0.40.0/24)
        # eth6 (vlan6) = network     (10.0.50.0/24)
        virtualisation.vlans = [1 2 3 4 5 6];

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
                {
                  udp.dport = 123;
                  verdict = "accept";
                  comment = "NTP";
                }
              ];
            };
            management = {
              icmpEcho = "enable";
              accessTo = ["management" "trusted" "untrusted"];
              forwardRules.external = [
                {
                  udp.dport = 53;
                  verdict = "accept";
                  comment = "DNS recursive queries";
                }
                {
                  tcp.dport = 53;
                  verdict = "accept";
                  comment = "DNS recursive queries (TCP)";
                }
                {
                  tcp.dport = 80;
                  verdict = "accept";
                  comment = "HTTP for package mirrors";
                }
                {
                  tcp.dport = 443;
                  verdict = "accept";
                  comment = "HTTPS for updates";
                }
                {
                  udp.dport = 123;
                  verdict = "accept";
                  comment = "NTP";
                }
              ];
              inputRules = [{verdict = "accept";}];
            };
            trusted = {
              icmpEcho = "enable";
              accessTo = ["management" "trusted" "untrusted" "external"];
              inputRules = [{verdict = "accept";}];
            };
            untrusted = {
              icmpEcho = "enable";
              accessTo = ["external"];
              inputRules = [
                {
                  udp.dport = [53 67 547];
                  verdict = "accept";
                }
                {
                  tcp.dport = 53;
                  verdict = "accept";
                }
              ];
            };
            isolated = {
              icmpEcho = "disable";
              accessTo = [];
              inputRules = [];
            };
          };

          dns = {
            upstream = ["1.1.1.1"];
            localDomain = "test.local";
          };

          topology = {
            eth1 = {
              hardwareName = "eth1";
              network = {
                type = "static";
                addresses = ["203.0.113.1/24"];
                zone = "external";
                nat.enable = true;
              };
            };
            eth2 = {
              hardwareName = "eth2";
              network = {
                type = "static";
                addresses = ["10.0.10.1/24" "fdc6:55f2:0a5e:a::1/64"];
                zone = "management";
                dhcp.enable = true;
              };
            };
            eth3 = {
              hardwareName = "eth3";
              network = {
                type = "static";
                addresses = ["10.0.20.1/24" "fdc6:55f2:0a5e:14::1/64"];
                zone = "trusted";
                dhcp.enable = true;
              };
            };
            eth4 = {
              hardwareName = "eth4";
              network = {
                type = "static";
                addresses = ["10.0.30.1/24"];
                zone = "untrusted";
                dhcp.enable = true;
              };
            };
            eth5 = {
              hardwareName = "eth5";
              network = {
                type = "static";
                addresses = ["10.0.40.1/24" "fdc6:55f2:0a5e:28::1/64"];
                zone = "isolated";
              };
            };
            eth6 = {
              hardwareName = "eth6";
              network = {
                type = "static";
                addresses = ["10.0.50.1/24"];
                zone = "network";
              };
            };
          };
        };

        # Test exercises zone firewall + kresd (:53 checks) — no DHCP probes.
        services.kea.dhcp4.enable = lib.mkForce false;
        services.kea.dhcp6.enable = lib.mkForce false;
      };

      # Management node
      mgmt = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [2];
        networking = {
          useDHCP = false;
          interfaces.eth1 = {
            ipv4.addresses = [
              {
                address = "10.0.10.100";
                prefixLength = 24;
              }
            ];
            ipv6.addresses = [
              {
                address = "fdc6:55f2:0a5e:a::100";
                prefixLength = 64;
              }
            ];
          };
          defaultGateway = "10.0.10.1";
          defaultGateway6 = {
            address = "fdc6:55f2:0a5e:a::1";
            interface = "eth1";
          };
        };
        environment.systemPackages = with pkgs; [netcat-gnu];
      };

      # Trusted node
      trusted = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [3];
        networking = {
          useDHCP = false;
          interfaces.eth1 = {
            ipv4.addresses = [
              {
                address = "10.0.20.100";
                prefixLength = 24;
              }
            ];
            ipv6.addresses = [
              {
                address = "fdc6:55f2:0a5e:14::100";
                prefixLength = 64;
              }
            ];
          };
          defaultGateway = "10.0.20.1";
          defaultGateway6 = {
            address = "fdc6:55f2:0a5e:14::1";
            interface = "eth1";
          };
        };
        environment.systemPackages = with pkgs; [netcat-gnu];
      };

      # Guest/untrusted node
      guest = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [4];
        networking = {
          useDHCP = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "10.0.30.100";
              prefixLength = 24;
            }
          ];
          defaultGateway = "10.0.30.1";
        };
        environment.systemPackages = with pkgs; [netcat-gnu];
      };

      # Isolated node
      isolated = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [5];
        networking = {
          useDHCP = false;
          interfaces.eth1 = {
            ipv4.addresses = [
              {
                address = "10.0.40.100";
                prefixLength = 24;
              }
            ];
            ipv6.addresses = [
              {
                address = "fdc6:55f2:0a5e:28::100";
                prefixLength = 64;
              }
            ];
          };
          defaultGateway = "10.0.40.1";
          defaultGateway6 = {
            address = "fdc6:55f2:0a5e:28::1";
            interface = "eth1";
          };
        };
        environment.systemPackages = with pkgs; [netcat-gnu];
      };

      # Network gear node (APs, switches)
      netgear = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [6];
        networking = {
          useDHCP = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "10.0.50.100";
              prefixLength = 24;
            }
          ];
          defaultGateway = "10.0.50.1";
        };
        environment.systemPackages = with pkgs; [netcat-gnu];
      };

      # External attacker node
      attacker = {
        config,
        pkgs,
        lib,
        ...
      }: {
        imports = [../lib/test-minimal-base.nix];
        virtualisation.vlans = [1];
        networking = {
          useDHCP = false;
          enableIPv6 = false;
          interfaces.eth1.ipv4.addresses = [
            {
              address = "203.0.113.100";
              prefixLength = 24;
            }
          ];
        };
        boot.kernel.sysctl = {
          "net.ipv6.conf.all.disable_ipv6" = 1;
          "net.ipv6.conf.default.disable_ipv6" = 1;
        };
        environment.systemPackages = with pkgs; [netcat-gnu];
      };
    };

    testScript = ''
      start_all()

      # Wait for all nodes
      router.wait_for_unit("network-online.target")
      router.wait_for_unit("nftables.service")

      mgmt.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.100'")
      trusted.wait_until_succeeds("ip addr show eth1 | grep '10.0.20.100'")
      guest.wait_until_succeeds("ip addr show eth1 | grep '10.0.30.100'")
      isolated.wait_until_succeeds("ip addr show eth1 | grep '10.0.40.100'")
      netgear.wait_until_succeeds("ip addr show eth1 | grep '10.0.50.100'")
      attacker.wait_until_succeeds("ip addr show eth1 | grep '203.0.113.100'")

      # Wait for DNS to be ready
      router.wait_until_succeeds("ss -tuln | grep ':53 '")

      # ======================================================================
      # INPUT CHAIN TESTS
      # ======================================================================

      # Test 1: management → router: full access
      print("Test 1: management -> router: full access")
      mgmt.succeed("timeout 5 nc -z -w 3 10.0.10.1 53")  # DNS
      mgmt.succeed("ping -c 1 -W 2 10.0.10.1")
      print("PASS")

      # Test 2: trusted → router: full access
      print("Test 2: trusted -> router: full access")
      trusted.succeed("timeout 5 nc -z -w 3 10.0.20.1 53")  # DNS
      trusted.succeed("ping -c 1 -W 2 10.0.20.1")
      print("PASS")

      # Test 3: untrusted → router: DNS/DHCP only
      print("Test 3: untrusted -> router: DNS/DHCP only")
      guest.succeed("timeout 5 nc -z -w 3 10.0.30.1 53")  # DNS allowed
      # SSH should be blocked (untrusted only gets DNS/DHCP via router services)
      guest.fail("timeout 3 nc -z -w 2 10.0.30.1 22")
      guest.fail("timeout 3 nc -z -w 2 10.0.30.1 80")
      print("PASS")

      # Test 4: isolated → router: nothing
      print("Test 4: isolated -> router: nothing (not even DNS)")
      isolated.fail("timeout 3 nc -z -w 2 10.0.40.1 53")  # DNS blocked
      isolated.fail("ping -c 1 -W 2 10.0.40.1")           # Ping blocked
      print("PASS")

      # Test 5: external → router: stealth
      print("Test 5: external -> router: stealth")
      attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 53")
      attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 22")
      attacker.fail("ping -c 1 -W 2 203.0.113.1")
      print("PASS")

      # Test 6: ICMP echo selective
      print("Test 6: ICMP echo - internal can ping, external/isolated cannot")
      mgmt.succeed("ping -c 1 -W 2 10.0.10.1")
      trusted.succeed("ping -c 1 -W 2 10.0.20.1")
      guest.succeed("ping -c 1 -W 2 10.0.30.1")
      netgear.succeed("ping -c 1 -W 2 10.0.50.1")
      isolated.fail("ping -c 1 -W 2 10.0.40.1")
      attacker.fail("ping -c 1 -W 2 203.0.113.1")
      print("PASS")

      # ======================================================================
      # FORWARD CHAIN TESTS
      # ======================================================================
      # Use ping for connectivity checks — it traverses the forward chain
      # without needing fragile background listener processes.

      # Test 7: management → trusted: allowed
      print("Test 7: management -> trusted: allowed")
      mgmt.succeed("ping -c 1 -W 2 10.0.20.100")
      print("PASS")

      # Test 8: management → untrusted: allowed
      print("Test 8: management -> untrusted: allowed")
      mgmt.succeed("ping -c 1 -W 2 10.0.30.100")
      print("PASS")

      # Test 9: management → external: allowed via forwardRules (HTTP/S, DNS, NTP)
      print("Test 9: management -> external: filtered via forwardRules (verified via rules)")
      router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth2.*oifname.*eth1.*udp dport 53 accept'")
      router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth2.*oifname.*eth1.*tcp dport 80 accept'")
      router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth2.*oifname.*eth1.*tcp dport 443 accept'")
      print("PASS")

      # Test 10: trusted → management: allowed
      print("Test 10: trusted -> management: allowed")
      trusted.succeed("ping -c 1 -W 2 10.0.10.100")
      print("PASS")

      # Test 11: trusted → untrusted: allowed
      print("Test 11: trusted -> untrusted: allowed")
      trusted.succeed("ping -c 1 -W 2 10.0.30.100")
      print("PASS")

      # Test 12: trusted → external: allowed (verified via rules)
      print("Test 12: trusted -> external: allowed (verified via rules)")
      router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth3.*oifname.*eth1.*accept'")
      print("PASS")

      # Test 13: untrusted → external: allowed (verified via rules)
      print("Test 13: untrusted -> external: allowed (verified via rules)")
      router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth4.*oifname.*eth1.*accept'")
      print("PASS")

      # Test 14: untrusted → management: blocked
      print("Test 14: untrusted -> management: blocked")
      guest.fail("ping -c 1 -W 2 10.0.10.100")
      print("PASS")

      # Test 15: untrusted → trusted: blocked
      print("Test 15: untrusted -> trusted: blocked")
      guest.fail("ping -c 1 -W 2 10.0.20.100")
      print("PASS")

      # Test 16: isolated → anything: blocked
      print("Test 16: isolated -> anything: blocked")
      isolated.fail("ping -c 1 -W 2 10.0.10.100")
      isolated.fail("ping -c 1 -W 2 10.0.20.100")
      isolated.fail("ping -c 1 -W 2 10.0.30.100")
      print("PASS")

      # Test 17: external → internal: blocked
      print("Test 17: external -> internal: blocked")
      attacker.fail("ping -c 1 -W 2 10.0.10.100")
      attacker.fail("ping -c 1 -W 2 10.0.20.100")
      attacker.fail("ping -c 1 -W 2 10.0.30.100")
      print("PASS")

      # ======================================================================
      # NETWORK ZONE TESTS
      # ======================================================================

      # Test 18: network → router: NTP (UDP 123) allowed
      print("Test 18: network -> router: NTP allowed")
      # Verify the NTP input rule exists for network zone
      router.succeed("nft list chain inet filter input | grep -E 'iifname.*eth6.*udp dport 123 accept'")
      print("PASS")

      # Test 19: network → router: DNS blocked
      print("Test 19: network -> router: DNS blocked")
      netgear.fail("timeout 3 nc -z -w 2 10.0.50.1 53")
      print("PASS")

      # Test 20: network → router: SSH blocked
      print("Test 20: network -> router: SSH blocked")
      netgear.fail("timeout 3 nc -z -w 2 10.0.50.1 22")
      print("PASS")

      # Test 21: network → any: no forwarding
      print("Test 21: network -> any: no forwarding")
      netgear.fail("ping -c 1 -W 2 10.0.10.100")
      netgear.fail("ping -c 1 -W 2 10.0.20.100")
      netgear.fail("ping -c 1 -W 2 10.0.30.100")
      print("PASS")

      # Test 22: management → external: forwardRules (SSH blocked)
      print("Test 22: management -> external: SSH blocked by forwardRules")
      # Verify there is no blanket accept from management to external
      router.fail("nft list chain inet filter forward | grep -E 'iifname.*eth2.*oifname.*eth1[^a-z].*accept$'")
      print("PASS")

      # ======================================================================
      # IPv6 TESTS
      # ======================================================================

      # Test 23: mgmt can ping6 router's management ULA
      print("Test 23: mgmt -> router: IPv6 ping allowed")
      mgmt.succeed("ping -6 -c 1 -W 3 fdc6:55f2:a5e:a::1")
      print("PASS")

      # Test 24: isolated cannot ping6 router's isolated ULA (icmpEcho = "disable")
      print("Test 24: isolated -> router: IPv6 ping blocked")
      isolated.fail("ping -6 -c 1 -W 2 fdc6:55f2:a5e:28::1")
      print("PASS")

      # Test 25: trusted can ping6 mgmt node (forward trusted→management)
      print("Test 25: trusted -> mgmt: IPv6 forward allowed")
      trusted.succeed("ping -6 -c 1 -W 3 fdc6:55f2:a5e:a::100")
      print("PASS")

      # Test 26: isolated cannot ping6 trusted node (forward blocked)
      print("Test 26: isolated -> trusted: IPv6 forward blocked")
      isolated.fail("ping -6 -c 1 -W 2 fdc6:55f2:a5e:14::100")
      print("PASS")

      # Test 27: mgmt can ping6 trusted node (forward management→trusted)
      print("Test 27: mgmt -> trusted: IPv6 forward allowed")
      mgmt.succeed("ping -6 -c 1 -W 3 fdc6:55f2:a5e:14::100")
      print("PASS")

      # Test 28: NDP rules present in nftables
      print("Test 28: NDP rules present in nftables")
      router.succeed("nft list ruleset | grep 'icmpv6 type'")
      print("PASS")

      # ======================================================================
      # Summary
      # ======================================================================
      print("")
      print("=" * 70)
      print("FIREWALL ZONE TESTS COMPLETE")
      print("=" * 70)
      print("All 28 tests passed.")
      print("=" * 70)
    '';
  }
