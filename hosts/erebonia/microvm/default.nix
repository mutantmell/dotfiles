{
  config,
  pkgs,
  microvm,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost "erebonia") host zone;
in {
  common.microvm = {
    enable = true;
    guestDir = ./guests;
  };

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "mk-volume-with-ssh-key";
      runtimeInputs = [pkgs.mmell.mk-volume];
      text = ''
        set -euxo pipefail
        if [ "$#" -lt 2 ]; then
          echo "invalid number of args"
          exit 1
        fi;

        NAME="$1"
        SIZE="$2"

        OUTDIR=./"$NAME".volume
        echo "$OUTDIR"
        if [ -d "$OUTDIR" ]; then
          echo "directory already exists"
          exit 2
        fi
        mkdir "$OUTDIR"
        cd "$OUTDIR"

        ssh-keygen -t ed25519 -f ssh_host_ed25519_key -q -N ""
        mkdir -p ./volume/static/ssh
        cp ssh_host_ed25519_key* ./volume/static/ssh/

        ${pkgs.mmell.mk-volume}/bin/mk-volume "$NAME" "$SIZE" "ext4" ./volume
      '';
    })
  ];

  systemd.network = {
    enable = true;
    links."01-uplink" = {
      matchConfig.Type = "ether";
      linkConfig.Name = "uplink";
    };
    netdevs."20-br11" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br11";
    };
    netdevs."20-br21" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br21";
    };
    # Cluster VLAN 51 bridge — host-IP-less (mirror br21, NOT br11): the
    # KubeVirt dev-machine attaches here via Multus + bridge CNI. The host
    # holds no VLAN-51 address, so this segment carries no host identity.
    netdevs."20-br51" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br51";
    };

    netdevs."20-uplink.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "uplink.11";
      vlanConfig.Id = 11;
    };
    netdevs."20-uplink.21" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "uplink.21";
      vlanConfig.Id = 21;
    };
    netdevs."20-uplink.50" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "uplink.50";
      vlanConfig.Id = 50;
    };
    netdevs."20-uplink.51" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "uplink.51";
      vlanConfig.Id = 51;
    };
    netdevs."20-uplink.100" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "uplink.100";
      vlanConfig.Id = 100;
    };
    networks."20-uplink" = {
      matchConfig.Name = "uplink";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "uplink.11"
        "uplink.21"
        "uplink.50"
        "uplink.51"
        "uplink.100"
      ];
    };
    networks."20-vm11-bridge" = {
      matchConfig.Name = ["uplink.11" "vm-11-*"];
      networkConfig.Bridge = "br11";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br11" = {
      matchConfig.Name = "br11";
      networkConfig.DHCP = "no";
      networkConfig.IPv6AcceptRA = true;
      networkConfig.IPv6PrivacyExtensions = "yes";
      networkConfig.Address = [host.cidr4 host.cidr6];
      networkConfig.DNS = [zone.gateway4 zone.gateway6];
      networkConfig.Domains = ["internal"];
      networkConfig.MulticastDNS = true;
      routes = [
        {Gateway = zone.gateway4;}
        {Gateway = zone.gateway6;}
      ];
    };
    networks."20-vm21-bridge" = {
      matchConfig.Name = ["uplink.21" "vm-21-*"];
      networkConfig.Bridge = "br21";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-uplink.50" = {
      matchConfig.Name = "uplink.50";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
    };
    # Enslave the VLAN-51 uplink (and any future microvm vm-51-* tap) into
    # br51. KubeVirt's bridge CNI enslaves the dev-VM veths into br51 itself.
    networks."20-vm51-bridge" = {
      matchConfig.Name = ["uplink.51" "vm-51-*"];
      networkConfig.Bridge = "br51";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    # macvtap interfaces for VLAN 50 guests: no host-side IP, just carrier
    networks."20-vm50-macvtap" = {
      matchConfig.Name = "vm-50-*";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
    };
    networks."20-uplink.100" = {
      matchConfig.Name = "uplink.100";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
    };
    # macvtap interfaces for VLAN 100 guests: no host-side IP, just carrier
    networks."20-vm100-macvtap" = {
      matchConfig.Name = "vm-100-*";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
    };
    networks."20-br21" = {
      matchConfig.Name = "br21";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    # br51 is deliberately host-IP-less (no Address, no DHCP, no
    # LinkLocalAddressing) — the low-trust cluster segment carries no host
    # identity. erebonia's management identity stays on br11/VLAN 11.
    #
    # Why br51 needs any L3 settings at all: k3s requires
    # net.bridge.bridge-nf-call-iptables=1 (cni0 + live NetworkPolicy depend on
    # it), which makes the kernel run br51's *bridged* VLAN-51 IPv4 frames
    # through the host IP stack's input/source-validation path (ARP and IPv6
    # bypass it — bridge-nf-call-ip6tables=0). Because br51 carries no address,
    # that path drops legitimate bridged frames in two distinct ways, each
    # needing its own fix below. erebonia still routes nothing and gains no
    # identity; bt8gw stays the sole VLAN-51 gateway/owner — these just stop the
    # host from sabotaging frames it is only supposed to be L2-switching.
    #
    # (1) Link-scoped route for the cluster subnet, with NO host address — fixes
    # the *destination* check. Without it the host's only route to 10.97.51.0/24
    # is the br11 default, so a frame to 10.97.51.x arriving on br51 is treated
    # as martian-destination (wrong egress) and dropped. The route states the L2
    # truth — br51 IS attached to VLAN 51 via the enslaved uplink.51 — i.e. the
    # connected route an address would have synthesized, added without taking
    # one. (A future host-IP-less L2 bridge switching a routed protocol for a
    # guest — e.g. br21 — needs the same one-line route.)
    #
    # (2) rp_filter = 0 (OFF, not merely "loose") — fixes the *source* check for
    # traffic routed IN from another subnet (the real lab→cluster access path:
    # e.g. edith on VLAN 21 → dev-N). On an address-less interface, when a
    # frame's source reverse-routes back out a *different* device (edith's source
    # routes via br11, not br51), __fib_validate_source takes a "last_resort"
    # path that rejects for ANY non-zero rp_filter — loose (2) included — so only
    # 0 passes. Intra-VLAN-51 sources (e.g. bt8gw .1) reverse-route via the br51
    # link route above and pass regardless; this knob is specifically what lets
    # cross-subnet, routed-in clients reach the dev VMs. networkd applies
    # IPv4ReversePathFilter per-link, so it sticks on this post-boot bridge — a
    # boot.kernel.sysctl drop-in would race br51's creation.
    networks."20-br51" = {
      matchConfig.Name = "br51";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
      networkConfig.IPv4ReversePathFilter = "no";
      routes = [
        {
          Destination = net.networks.cluster.subnet4;
          Scope = "link";
        }
      ];
    };
  };
  services.resolved.enable = true;

  # Wait for VLAN 50 before setting up macvtap interfaces
  systemd.services."microvm-macvtap-interfaces@saint-arkh" = {
    after = ["sys-subsystem-net-devices-uplink.50.device"];
    wants = ["sys-subsystem-net-devices-uplink.50.device"];
  };

  # Host-based input firewall: restrict SSH to router + vHOME
  networking.firewall.extraInputRules = ''
    ip saddr { ${zone.gateway4}, ${net.networks.trusted.subnet4} } tcp dport 22 accept
    ip6 saddr { ${zone.gateway6}, ${net.networks.trusted.subnet6} } tcp dport 22 accept
    tcp dport 22 drop
  '';
}
