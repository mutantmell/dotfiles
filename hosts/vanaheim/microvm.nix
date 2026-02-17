{
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
      networkConfig.Address = [ "10.0.11.30/24" "fdc6:55f2:0a5e:b::1e/64" ];
      networkConfig.MulticastDNS = true;
      routes = [
        { Gateway = "10.0.11.1"; }
        { Gateway = "fdc6:55f2:0a5e:b::1"; }
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
      ip saddr { 10.0.11.1, 10.0.20.0/24 } tcp dport 22 accept
      ip6 saddr { fdc6:55f2:0a5e:b::1, fdc6:55f2:0a5e:14::/64 } tcp dport 22 accept
      tcp dport 22 drop
    '';
  };
}
