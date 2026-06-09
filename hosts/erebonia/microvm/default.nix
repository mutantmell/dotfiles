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
    # ONE exception to "no L3 on br51": a link-scoped route for the cluster
    # subnet, with NO host address. This is forced by br_netfilter, not by any
    # routing role. k3s requires net.bridge.bridge-nf-call-iptables=1 (cni0 +
    # live NetworkPolicy depend on it), and that makes the kernel run br51's
    # *bridged* VLAN-51 IPv4 frames through the host IP stack. With br51 address-
    # less, the host's only route to 10.97.51.0/24 is the br11 default, so the
    # IP stack treats VLAN-51 frames arriving on br51 as martian-source and
    # silently drops them *before* the forward hook (the dev VM answers ARP — L2,
    # which bypasses this — but black-holes every routed IPv4 packet; IPv6 is
    # unaffected because bridge-nf-call-ip6tables=0). The KubeVirt dev-machine
    # bridge-binding (multus → bridge CNI onto br51) is the only thing that needs
    # the host to switch VLAN-51 frames, so it is the first to hit this.
    #
    # The route just states the L2 truth — br51 IS attached to VLAN 51 via the
    # enslaved uplink.51 — which is the connected route an address would have
    # synthesized; we add it without taking an address. That gives the IP stack
    # the context to stop flagging the frames martian, restoring L2 delivery.
    # bt8gw stays the sole VLAN-51 gateway/owner; erebonia gains no identity and
    # routes nothing (no address to source from). Any future host-IP-less L2
    # bridge that must switch a *routed* protocol for a guest (e.g. br21 once it
    # carries one) needs the same one-line route.
    networks."20-br51" = {
      matchConfig.Name = "br51";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
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
