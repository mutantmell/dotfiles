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
    netdevs."20-enp88s0.10" = {
      netdevConfig.Kind = "vlan";
      netdevConfig.Name = "enp88s0.10";
      vlanConfig.Id = 10;
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
        "enp88s0.10"
        "enp88s0.20"
        "enp88s0.100"
      ];
    };
    networks."20-enp88s0.10" = {
      matchConfig.Name = "enp88s0.10";
      networkConfig.DHCP = "no";
      networkConfig.IPv6PrivacyExtensions = "kernel";
      networkConfig.Address = [ "10.0.10.30/24" ];
      networkConfig.MulticastDNS = true;
      routes = [ { routeConfig.Gateway = "10.0.10.1"; }];
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
}
