{
  config,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost "calvard") host zone;
in {
  common.microvm = {
    enable = true;
    guestDir = ./guests;
  };

  # Boot ordering: start ACME-dependent guests after basel (step-ca).
  # Uses Wants (not Requires) so guests still start if basel is down —
  # they'll run with persisted certs in a degraded state rather than
  # refusing to start entirely.
  systemd.services = let
    afterBasel = {
      after = ["microvm@basel.service"];
      wants = ["microvm@basel.service"];
    };
  in {
    "microvm@messeldam" = afterBasel;
    "microvm@langport" = afterBasel;
    "microvm@creil" = afterBasel;
    "microvm@oracion" = afterBasel;
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
    # vINFRA (VLAN 11) — messeldam, basel, tharbad
    netdevs."20-br11" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br11";
    };
    # vLAB (VLAN 21) — edith
    netdevs."20-br21" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br21";
    };
    # vDMZ (VLAN 100) — langport, oracion
    netdevs."20-br100" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br100";
    };
    netdevs."20-enp88s0.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp88s0.11";
      vlanConfig.Id = 11;
    };
    netdevs."20-enp88s0.21" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp88s0.21";
      vlanConfig.Id = 21;
    };
    netdevs."20-enp88s0.100" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp88s0.100";
      vlanConfig.Id = 100;
    };
    networks."20-enp88s0" = {
      matchConfig.Name = "enp88s0";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      vlan = [
        "enp88s0.11"
        "enp88s0.21"
        "enp88s0.100"
      ];
    };
    # Bridge enp88s0.11 and all vm-11-* tap interfaces into br11
    networks."20-vm11-bridge" = {
      matchConfig.Name = ["enp88s0.11" "vm-11-*"];
      networkConfig.Bridge = "br11";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    # Host IP on br11 (vINFRA management)
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
      matchConfig.Name = ["enp88s0.21"];
      networkConfig.Bridge = "br21";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-vm100-bridge" = {
      matchConfig.Name = ["enp88s0.100" "vm-100-*"];
      networkConfig.Bridge = "br100";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br21" = {
      matchConfig.Name = "br21";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br100" = {
      matchConfig.Name = "br100";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
  };
  services.resolved.enable = true;

  # Host-based input firewall: restrict SSH to router + vHOME
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [9100];
    extraInputRules = ''
      ip saddr { ${zone.gateway4}, ${net.networks.trusted.subnet4} } tcp dport 22 accept
      ip6 saddr { ${zone.gateway6}, ${net.networks.trusted.subnet6} } tcp dport 22 accept
      tcp dport 22 drop
    '';
  };
}
