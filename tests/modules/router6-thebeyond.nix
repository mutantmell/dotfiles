# NixOS integration test for thebeyond router configuration
#
# TEMPORARY: Pre-deployment validation. Remove after thebeyond is successfully
# deployed and the config is confirmed working on physical hardware. The generic
# router6 module tests (router6-firewall-zones, etc.) provide ongoing coverage.
#
# Tests the actual thebeyond zone config and firewall rules on a flat VM topology.
# Bond/batman/bridge/VLAN stacking can't be replicated in test VMs, so we use
# one interface per zone. The snapshot test covers the full topology with real
# interface names.
#
# Test nodes:
#   router:   eth1-eth7 (wan, mgmt, infra, home, guest, iot, dmz)
#   mgmt:     10.0.10.100 (network zone)
#   infra:    10.0.11.100 (management zone)
#   home:     10.0.20.100 (trusted zone)
#   guest:    10.0.30.100 (untrusted zone)
#   iot:      10.0.40.100 (untrusted zone)
#   dmz:      10.0.100.100 (untrusted zone)
#   attacker: 203.0.113.100 (external zone)

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  # Hardcoded IPs from network registry (same as hosts/thebeyond/default.nix)
  host      = { ipv4 = "10.0.11.1"; ipv6 = "fdc6:55f2:0a5e:b::1"; };
  phantasma = { ipv4 = "10.0.11.2"; ipv6 = "fdc6:55f2:0a5e:b::2"; };
  ordis     = { ipv4 = "10.0.100.40"; ipv6 = "fdc6:55f2:0a5e:64::28"; };
  roer      = { ipv4 = "10.0.11.3"; ipv6 = "fdc6:55f2:0a5e:b::3"; };
  legram    = { ipv4 = "10.0.11.4"; ipv6 = "fdc6:55f2:0a5e:b::4"; };
in

pkgs.testers.nixosTest {
  name = "router6-thebeyond";

  nodes = {
    router = { config, pkgs, lib, ... }: {
      imports = [ ../../modules/router6 ];

      # Flat topology: eth1-eth7 map to thebeyond's zones
      virtualisation.vlans = [ 1 2 3 4 5 6 7 ];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        # ============================================================
        # Zones: identical to hosts/thebeyond/default.nix
        # ============================================================
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
          upstream = [ "1.1.1.1" ];
          useDHCPFallback = false;
          localDomain = "internal";
        };

        firewall = {
          # Adapted extraForwardRules: flat interface names
          # DMZ (eth7) -> infra (eth3) selective rules
          extraForwardRules = [
            # ordis -> roer (OIDC token exchange)
            { iifname = "eth7"; oifname = "eth3";
              ip.saddr = ordis.ipv4; ip.daddr = roer.ipv4;
              tcp.dport = 443; verdict = "accept"; comment = "ordis -> roer (OIDC)"; }
            { iifname = "eth7"; oifname = "eth3";
              ip6.saddr = ordis.ipv6; ip6.daddr = roer.ipv6;
              tcp.dport = 443; verdict = "accept"; comment = "ordis -> roer (OIDC v6)"; }
            # DMZ -> legram (ACME certificate issuance)
            { iifname = "eth7"; oifname = "eth3";
              ip.daddr = legram.ipv4; tcp.dport = 443;
              verdict = "accept"; comment = "vDMZ -> legram (ACME)"; }
            { iifname = "eth7"; oifname = "eth3";
              ip6.daddr = legram.ipv6; tcp.dport = 443;
              verdict = "accept"; comment = "vDMZ -> legram (ACME v6)"; }
          ];

          # Wireguard BA tunnel masquerading (uses eth1 as stand-in for wg-ba)
          extraNatPostroutingRules = [
            { oifname = "eth1"; masquerade = true; }
            { iifname = "eth1"; ip.daddr = ordis.ipv4; masquerade = true; }
          ];

          # DNS interception rules (same IPs as thebeyond)
          extraNatRules = [
            {
              ip.saddr = { not = phantasma.ipv4; };
              ip.daddr = { not = [ host.ipv4 phantasma.ipv4 ]; };
              udp.dport = 53;
              verdict = { dnat = "${host.ipv4}:53"; };
              comment = "Intercept DNS bypass (UDP)";
            }
            {
              ip.saddr = { not = phantasma.ipv4; };
              ip.daddr = { not = [ host.ipv4 phantasma.ipv4 ]; };
              tcp.dport = 53;
              verdict = { dnat = "${host.ipv4}:53"; };
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

        # ============================================================
        # Flat topology: one interface per zone
        # ============================================================
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
              zone = "network";
            };
          };
          eth3 = {
            hardwareName = "eth3";
            network = {
              type = "static";
              addresses = [ "10.0.11.1/24" ];
              zone = "management";
              dhcp.enable = true;
            };
          };
          eth4 = {
            hardwareName = "eth4";
            network = {
              type = "static";
              addresses = [ "10.0.20.1/24" ];
              zone = "trusted";
              dhcp.enable = true;
            };
          };
          eth5 = {
            hardwareName = "eth5";
            network = {
              type = "static";
              addresses = [ "10.0.30.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
            };
          };
          eth6 = {
            hardwareName = "eth6";
            network = {
              type = "static";
              addresses = [ "10.0.40.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
            };
          };
          eth7 = {
            hardwareName = "eth7";
            network = {
              type = "static";
              addresses = [ "10.0.100.1/24" ];
              zone = "untrusted";
              dhcp.enable = true;
            };
          };
        };
      };
    };

    # Network gear node (network zone)
    mgmt = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 2 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.10.100"; prefixLength = 24; }];
        defaultGateway = "10.0.10.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # Infrastructure node (management zone)
    infra = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 3 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.11.100"; prefixLength = 24; }];
        defaultGateway = "10.0.11.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # Home node (trusted zone)
    home = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 4 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.20.100"; prefixLength = 24; }];
        defaultGateway = "10.0.20.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # Guest node (untrusted zone)
    guest = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 5 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.30.100"; prefixLength = 24; }];
        defaultGateway = "10.0.30.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # IoT node (untrusted zone, separate interface)
    iot = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 6 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.40.100"; prefixLength = 24; }];
        defaultGateway = "10.0.40.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # DMZ node (untrusted zone, has extra forward rules)
    dmz = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 7 ];
      networking = {
        useDHCP = false;
        interfaces.eth1.ipv4.addresses = [{ address = "10.0.100.100"; prefixLength = 24; }];
        defaultGateway = "10.0.100.1";
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };

    # External attacker node
    attacker = { config, pkgs, lib, ... }: {
      virtualisation.vlans = [ 1 ];
      networking = {
        useDHCP = false;
        enableIPv6 = false;
        interfaces.eth1.ipv4.addresses = [{ address = "203.0.113.100"; prefixLength = 24; }];
      };
      boot.kernel.sysctl = {
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };
      environment.systemPackages = with pkgs; [ netcat-gnu ];
    };
  };

  testScript = ''
    start_all()

    # Wait for all nodes
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("nftables.service")

    mgmt.wait_until_succeeds("ip addr show eth1 | grep '10.0.10.100'")
    infra.wait_until_succeeds("ip addr show eth1 | grep '10.0.11.100'")
    home.wait_until_succeeds("ip addr show eth1 | grep '10.0.20.100'")
    guest.wait_until_succeeds("ip addr show eth1 | grep '10.0.30.100'")
    iot.wait_until_succeeds("ip addr show eth1 | grep '10.0.40.100'")
    dmz.wait_until_succeeds("ip addr show eth1 | grep '10.0.100.100'")
    attacker.wait_until_succeeds("ip addr show eth1 | grep '203.0.113.100'")

    # Wait for DNS to be ready
    router.wait_until_succeeds("ss -tuln | grep ':53 '")

    # ======================================================================
    # 1. SERVICES START
    # ======================================================================

    print("Test 1a: nftables running")
    router.succeed("systemctl is-active nftables.service")
    print("PASS")

    print("Test 1b: kresd DNS running")
    router.succeed("systemctl is-active kresd@1.service")
    print("PASS")

    print("Test 1c: kea DHCP4 running")
    router.succeed("systemctl is-active kea-dhcp4-server.service")
    print("PASS")

    # ======================================================================
    # 2. INPUT CHAIN - ZONE ISOLATION
    # ======================================================================

    # management zone (infra): full router access
    print("Test 2a: management -> router: full access")
    infra.succeed("timeout 5 nc -z -w 3 10.0.11.1 53")
    infra.succeed("ping -c 1 -W 2 10.0.11.1")
    print("PASS")

    # trusted zone (home): full router access
    print("Test 2b: trusted -> router: full access")
    home.succeed("timeout 5 nc -z -w 3 10.0.20.1 53")
    home.succeed("ping -c 1 -W 2 10.0.20.1")
    print("PASS")

    # untrusted zone (guest): DNS/DHCP only
    print("Test 2c: untrusted -> router: DNS/DHCP only")
    guest.succeed("timeout 5 nc -z -w 3 10.0.30.1 53")
    guest.fail("timeout 3 nc -z -w 2 10.0.30.1 22")
    guest.fail("timeout 3 nc -z -w 2 10.0.30.1 80")
    print("PASS")

    # untrusted zone (iot): same restrictions as guest
    print("Test 2d: untrusted (iot) -> router: DNS/DHCP only")
    iot.succeed("timeout 5 nc -z -w 3 10.0.40.1 53")
    iot.fail("timeout 3 nc -z -w 2 10.0.40.1 22")
    print("PASS")

    # untrusted zone (dmz): same restrictions
    print("Test 2e: untrusted (dmz) -> router: DNS/DHCP only")
    dmz.succeed("timeout 5 nc -z -w 3 10.0.100.1 53")
    dmz.fail("timeout 3 nc -z -w 2 10.0.100.1 22")
    print("PASS")

    # network zone (mgmt): NTP only
    print("Test 2f: network -> router: NTP only")
    router.succeed("nft list chain inet filter input | grep -E 'iifname.*eth2.*udp dport 123 accept'")
    mgmt.fail("timeout 3 nc -z -w 2 10.0.10.1 53")
    mgmt.fail("timeout 3 nc -z -w 2 10.0.10.1 22")
    print("PASS")

    # external zone (attacker): stealth
    print("Test 2g: external -> router: stealth")
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 53")
    attacker.fail("timeout 3 nc -z -w 2 203.0.113.1 22")
    print("PASS")

    # ======================================================================
    # 3. FORWARD CHAIN - ZONE ISOLATION
    # ======================================================================

    # trusted -> all internal + external: allowed
    print("Test 3a: trusted -> management: allowed")
    home.succeed("ping -c 1 -W 2 10.0.11.100")
    print("PASS")

    print("Test 3b: trusted -> untrusted: allowed")
    home.succeed("ping -c 1 -W 2 10.0.30.100")
    print("PASS")

    print("Test 3c: trusted -> external: allowed (via rules)")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth4.*oifname.*eth1.*accept'")
    print("PASS")

    # management -> management/trusted/untrusted: allowed
    print("Test 3d: management -> trusted: allowed")
    infra.succeed("ping -c 1 -W 2 10.0.20.100")
    print("PASS")

    print("Test 3e: management -> untrusted: allowed")
    infra.succeed("ping -c 1 -W 2 10.0.30.100")
    print("PASS")

    # management -> external: only HTTP/S, DNS, NTP (filtered via forwardRules)
    print("Test 3f: management -> external: forwardRules present")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth3.*oifname.*eth1.*udp dport 53 accept'")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth3.*oifname.*eth1.*tcp dport 80 accept'")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth3.*oifname.*eth1.*tcp dport 443 accept'")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth3.*oifname.*eth1.*udp dport 123 accept'")
    print("PASS")

    print("Test 3g: management -> external: no blanket accept (SSH blocked)")
    router.fail("nft list chain inet filter forward | grep -E 'iifname.*eth3.*oifname.*eth1[^a-z].*accept$'")
    print("PASS")

    # untrusted -> external: allowed
    print("Test 3h: untrusted -> external: allowed (via rules)")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth5.*eth6.*eth7.*oifname.*eth1.*accept'")
    print("PASS")

    # untrusted -> management: blocked
    print("Test 3i: untrusted -> management: blocked")
    guest.fail("ping -c 1 -W 2 10.0.11.100")
    print("PASS")

    # untrusted -> trusted: blocked
    print("Test 3j: untrusted -> trusted: blocked")
    guest.fail("ping -c 1 -W 2 10.0.20.100")
    print("PASS")

    # iot (untrusted) -> management: also blocked
    print("Test 3k: iot (untrusted) -> management: blocked")
    iot.fail("ping -c 1 -W 2 10.0.11.100")
    print("PASS")

    # network -> anything: blocked
    print("Test 3l: network -> any: no forwarding")
    mgmt.fail("ping -c 1 -W 2 10.0.11.100")
    mgmt.fail("ping -c 1 -W 2 10.0.20.100")
    mgmt.fail("ping -c 1 -W 2 10.0.30.100")
    print("PASS")

    # external -> internal: blocked
    print("Test 3m: external -> internal: blocked")
    attacker.fail("ping -c 1 -W 2 10.0.11.100")
    attacker.fail("ping -c 1 -W 2 10.0.20.100")
    attacker.fail("ping -c 1 -W 2 10.0.30.100")
    print("PASS")

    # ======================================================================
    # 4. EXTRA FORWARD RULES (thebeyond-specific)
    # ======================================================================

    # DMZ -> infra selective: ordis -> roer OIDC
    # Note: nftables DSL renders oifname AFTER ip saddr/daddr
    print("Test 4a: DMZ -> infra: ordis -> roer OIDC rule present")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth7.*ip saddr 10.0.100.40.*ip daddr 10.0.11.3.*oifname.*eth3.*tcp dport 443 accept'")
    print("PASS")

    # DMZ -> infra: DMZ -> legram ACME
    print("Test 4b: DMZ -> infra: DMZ -> legram ACME rule present")
    router.succeed("nft list chain inet filter forward | grep -E 'iifname.*eth7.*ip daddr 10.0.11.4.*oifname.*eth3.*tcp dport 443 accept'")
    print("PASS")

    # ======================================================================
    # 5. NAT RULES
    # ======================================================================

    # DNS interception DNAT rules (IPv4)
    print("Test 5a: DNS interception DNAT (IPv4 UDP)")
    router.succeed("nft list chain ip nat prerouting | grep -E 'ip saddr != 10.0.11.2.*udp dport 53.*dnat to 10.0.11.1:53'")
    print("PASS")

    print("Test 5b: DNS interception DNAT (IPv4 TCP)")
    router.succeed("nft list chain ip nat prerouting | grep -E 'ip saddr != 10.0.11.2.*tcp dport 53.*dnat to 10.0.11.1:53'")
    print("PASS")

    # DNS interception DNAT rules (IPv6)
    print("Test 5c: DNS interception DNAT (IPv6 UDP)")
    router.succeed("nft list chain ip6 nat prerouting | grep 'udp dport 53'")
    print("PASS")

    print("Test 5d: DNS interception DNAT (IPv6 TCP)")
    router.succeed("nft list chain ip6 nat prerouting | grep 'tcp dport 53'")
    print("PASS")

    # NAT masquerade on WAN
    print("Test 5e: NAT masquerade on external interface")
    router.succeed("nft list chain ip nat postrouting | grep -E 'oifname.*eth1.*masquerade'")
    print("PASS")

    # Extra postrouting masquerade rules
    print("Test 5f: Extra postrouting masquerade rules loaded")
    router.succeed("nft list chain ip nat postrouting | grep -E 'iifname.*eth1.*ip daddr.*masquerade'")
    print("PASS")

    # ======================================================================
    # 6. ICMP ECHO POLICY
    # ======================================================================

    print("Test 6a: management/trusted/untrusted/network can ping router")
    mgmt.succeed("ping -c 1 -W 2 10.0.10.1")
    infra.succeed("ping -c 1 -W 2 10.0.11.1")
    home.succeed("ping -c 1 -W 2 10.0.20.1")
    guest.succeed("ping -c 1 -W 2 10.0.30.1")
    iot.succeed("ping -c 1 -W 2 10.0.40.1")
    dmz.succeed("ping -c 1 -W 2 10.0.100.1")
    print("PASS")

    print("Test 6b: external cannot ping router")
    attacker.fail("ping -c 1 -W 2 203.0.113.1")
    print("PASS")

    # ======================================================================
    # Summary
    # ======================================================================
    print("")
    print("=" * 70)
    print("THEBEYOND ROUTER TESTS COMPLETE")
    print("=" * 70)
    print("All tests passed.")
    print("=" * 70)
  '';
}
