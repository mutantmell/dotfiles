{ pkgs, ... }:

let
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost "calvard") host zone;
in {
  systemd.network = {
    enable = true;
    netdevs."20-br20" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br20";
    };
    netdevs."20-br100" = {
      netdevConfig.Kind = "bridge";
      netdevConfig.Name = "br100";
    };
    netdevs."20-enp88s0.11" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp88s0.11";
      vlanConfig.Id = 11;
    };
    netdevs."20-enp88s0.20" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp88s0.20";
      vlanConfig.Id = 20;
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
        "enp88s0.20"
        "enp88s0.100"
      ];
    };
    networks."20-enp88s0.11" = {
      matchConfig.Name = "enp88s0.11";
      networkConfig.DHCP = "no";
      networkConfig.IPv6AcceptRA = false;
      networkConfig.Address = [ host.cidr4 host.cidr6 ];
      networkConfig.MulticastDNS = true;
      routes = [
        { Gateway = zone.gateway4; }
        { Gateway = zone.gateway6; }
      ];
    };
    networks."20-vm20-bridge" = {
      matchConfig.Name = [ "enp88s0.20" "vm-20-*" ];
      networkConfig.Bridge = "br20";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-vm100-bridge" = {
      matchConfig.Name = [ "enp88s0.100" "vm-100-*" ];
      networkConfig.Bridge = "br100";
      networkConfig.DHCP = "no";
      networkConfig.LinkLocalAddressing = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
    };
    networks."20-br20" = {
      matchConfig.Name = "br20";
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
    extraInputRules = ''
      ip saddr { ${zone.gateway4}, ${net.networks.trusted.subnet4} } tcp dport 22 accept
      ip6 saddr { ${zone.gateway6}, ${net.networks.trusted.subnet6} } tcp dport 22 accept
      tcp dport 22 drop
    '';
  };
}
