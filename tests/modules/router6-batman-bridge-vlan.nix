# NixOS integration test for batman-adv + per-VLAN bridge topology
#
# Replicates the thebeyond topology: bond → batman, then per-VLAN bridges
# joining bond0 VLANs (wired trunk) + bat0 VLANs (mesh) for each VLAN tag.
#
# Key invariant: bond0 must NOT be a direct bridge member when it's already
# a batman hard-interface. Only VLAN sub-interfaces of bond0 and bat0 should
# be bridge members. Traffic flows:
#   Wired: bond0 → vHOME.bond0 (tag 20) → brHOME (bridge) → IP
#   Mesh:  bond0 → bat0 → vHOME.bat0 (tag 20) → brHOME (bridge) → IP
#
# Batman-adv only forwards mesh-encapsulated frames (ethertype 0x4305) on
# hard interfaces, so a direct client can't get DHCP through bat0 in a VM.
# To test DHCP end-to-end, we add a direct physical port (eth3) with a VLAN 20
# sub-interface as a third bridge member — the client connects there with a
# VLAN 20 tag. This mirrors how opt2 works on the real router as a diagnostic port.

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

pkgs.testers.nixosTest {
  name = "router6-batman-bridge-vlan";

  nodes = {
    router = { config, pkgs, ... }: {
      imports = [ ../../modules/router6 ];

      # eth0 = test driver, eth1 = WAN, eth2 = LAN (bonded),
      # eth3 = direct bridge port (shared with client for DHCP test)
      virtualisation.vlans = [ 1 2 3 ];

      # Batman-adv kernel module
      boot.extraModulePackages = [ config.boot.kernelPackages.batman_adv ];
      boot.kernelModules = [ "batman-adv" ];

      router6 = {
        enable = true;
        ulaPrefix = "fdc6:55f2:0a5e::/48";

        zones = {
          external = {
            icmpEcho = "disable";
            accessTo = [];
            inputRules = [];
          };
          trusted = {
            icmpEcho = "enable";
            accessTo = [ "trusted" "external" ];
            inputRules = [{ verdict = "accept"; }];
          };
        };

        topology = {
          # WAN interface
          wan = {
            hardwareName = "eth1";
            network = {
              type = "static";
              addresses = [ "192.168.1.1/24" ];
              zone = "external";
              nat.enable = true;
            };
          };

          # LAN physical interface — bonded into batman mesh
          lan = {
            hardwareName = "eth2";
          };

          # Bond (active-backup, single member for VM simplicity)
          bond0 = {
            kind = "bond";
            mode = "active-backup";
            members = [ "lan" ];
            network = {
              type = "disabled";
              mtu = 1536;
            };
            vlans = {
              "vHOME.bond0" = { tag = 20; network.type = "disabled"; };
            };
          };

          # Batman-adv mesh device
          bat0 = {
            kind = "batman";
            members = [ "bond0" ];
            batman = {
              gatewayMode = "off";
              routingAlgorithm = "batman-v";
            };
            network.type = "disabled";
            vlans = {
              "vHOME.bat0" = { tag = 20; network.type = "disabled"; };
            };
          };

          # Direct physical port — provides wired VLAN 20 access for test client
          eth3 = {
            hardwareName = "eth3";
            network.type = "disabled";
            vlans = {
              "vHOME.eth3" = { tag = 20; network.type = "disabled"; };
            };
          };

          # Per-VLAN bridge: bond0 VLAN (wired) + bat0 VLAN (mesh) + eth3 VLAN (test port)
          brHOME = {
            kind = "bridge";
            members = [ "vHOME.bond0" "vHOME.bat0" "vHOME.eth3" ];
            network = {
              type = "static";
              addresses = [ "10.0.20.1/24" ];
              subnetId = 20;
              zone = "trusted";
              dhcp.enable = true;
              dhcp6.enable = true;
            };
          };
        };
      };
    };

    # Client on the same L2 as router's eth3 (direct bridge port)
    client = { ... }: {
      virtualisation.vlans = [ 3 ];
      networking = {
        useDHCP = false;
        vlans.vlan20 = {
          id = 20;
          interface = "eth1";
        };
        interfaces.vlan20.useDHCP = true;
      };
    };
  };

  testScript = ''
    start_all()

    # Wait for router networking
    router.wait_for_unit("network-online.target")
    router.wait_for_unit("kea-dhcp4-server.service")

    # ======================================================================
    # 1. BATMAN TOPOLOGY VERIFICATION
    # ======================================================================

    print("Test 1a: bond0 exists with lan member")
    router.succeed("ip link show bond0")
    router.succeed("cat /sys/class/net/bond0/bonding/slaves | grep lan")
    print("PASS")

    print("Test 1b: bat0 exists (batman-adv netdev)")
    router.succeed("ip link show bat0")
    print("PASS")

    print("Test 1c: brHOME has VLAN sub-interfaces as bridge members")
    router.succeed("bridge link show | grep 'vHOME.bond0'")
    router.succeed("bridge link show | grep 'vHOME.bat0'")
    router.succeed("bridge link show | grep 'vHOME.eth3'")
    print("PASS")

    print("Test 1d: bond0 is NOT a direct bridge member")
    router.fail("bridge link show dev bond0 2>/dev/null | grep -q .")
    print("PASS")

    print("Test 1e: bat0 is NOT a direct bridge member")
    router.fail("bridge link show dev bat0 2>/dev/null | grep -q .")
    print("PASS")

    # ======================================================================
    # 2. SYSTEMD-NETWORKD CONFIG
    # ======================================================================

    print("Test 2a: Correct netdev ordering (bond < batman < bridge < vlan)")
    router.succeed("ls /etc/systemd/network/01-bond0.netdev")
    router.succeed("ls /etc/systemd/network/02-bat0.netdev")
    router.succeed("ls /etc/systemd/network/03-brHOME.netdev")
    router.succeed("ls /etc/systemd/network/04-vHOME.bond0.netdev")
    router.succeed("ls /etc/systemd/network/04-vHOME.bat0.netdev")
    router.succeed("ls /etc/systemd/network/04-vHOME.eth3.netdev")
    print("PASS")

    print("Test 2b: bond0 has BatmanAdvanced= but NOT Bridge=")
    router.succeed("grep 'BatmanAdvanced=bat0' /etc/systemd/network/10-bond0.network")
    router.fail("grep 'Bridge=' /etc/systemd/network/10-bond0.network")
    print("PASS")

    print("Test 2c: VLAN network files assign to brHOME")
    router.succeed("grep 'Bridge=brHOME' /etc/systemd/network/21-vHOME.bond0.network")
    router.succeed("grep 'Bridge=brHOME' /etc/systemd/network/21-vHOME.bat0.network")
    router.succeed("grep 'Bridge=brHOME' /etc/systemd/network/21-vHOME.eth3.network")
    print("PASS")

    # ======================================================================
    # 3. BRIDGE ADDRESSES
    # ======================================================================

    print("Test 3a: brHOME has correct IPv4")
    router.succeed("ip addr show brHOME | grep '10.0.20.1/24'")
    print("PASS")

    print("Test 3b: brHOME has auto-generated IPv6")
    router.succeed("ip addr show brHOME | grep 'fdc6:55f2:a5e:14::1/64'")
    print("PASS")

    # ======================================================================
    # 4. DHCP END-TO-END (client via direct bridge port + VLAN 20)
    # ======================================================================

    print("Test 4a: Client gets DHCP lease on VLAN 20")
    client.wait_until_succeeds("ip addr show vlan20 | grep '10.0.20'", timeout=60)
    print("PASS")

    print("Test 4b: Client can ping router")
    client.succeed("ping -c 1 -W 5 10.0.20.1")
    print("PASS")

    print("Test 4c: IPv6 SLAAC works through bridge VLAN")
    client.wait_until_succeeds("ip -6 addr show vlan20 | grep 'fdc6:55f2:a5e:14'", timeout=60)
    print("PASS")

    # ======================================================================
    # Summary
    # ======================================================================
    print("")
    print("=" * 70)
    print("PER-VLAN BRIDGE + BATMAN TOPOLOGY TESTS COMPLETE")
    print("=" * 70)
  '';
}
