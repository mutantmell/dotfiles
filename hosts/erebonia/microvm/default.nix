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
    netdevs."20-br11" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br11";
    };
    netdevs."20-br21" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br21";
    };

    netdevs."20-eno1.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.11";
      vlanConfig.Id = 11;
    };
    netdevs."20-eno1.21" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.21";
      vlanConfig.Id = 21;
    };
    netdevs."20-eno1.100" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "eno1.100";
      vlanConfig.Id = 100;
    };
    networks."20-eno1" = {
      matchConfig.Name = "eno1";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "eno1.11"
        "eno1.21"
        "eno1.100"
      ];
    };
    networks."20-vm11-bridge" = {
      matchConfig.Name = ["eno1.11" "vm-11-*"];
      networkConfig.Bridge = "br11";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br11" = {
      matchConfig.Name = "br11";
      networkConfig.DHCP = "no";
      networkConfig.IPv6AcceptRA = false;
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
      matchConfig.Name = ["eno1.21" "vm-21-*"];
      networkConfig.Bridge = "br21";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-eno1.100" = {
      matchConfig.Name = "eno1.100";
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
  };
  services.resolved.enable = true;

  # Host-based input firewall: restrict SSH to router + vHOME
  networking.firewall.extraInputRules = ''
    ip saddr { ${zone.gateway4}, ${net.networks.trusted.subnet4} } tcp dport 22 accept
    ip6 saddr { ${zone.gateway6}, ${net.networks.trusted.subnet6} } tcp dport 22 accept
    tcp dport 22 drop
  '';
}
