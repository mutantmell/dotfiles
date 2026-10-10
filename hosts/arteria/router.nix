# Router-on-a-stick: ordinary tagged Ethernet from the office switch, not a
# BATMAN hard interface. OpenWrt bridges mesh VLANs onto the switch separately.
{
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  ds = net.mkDualStackRules;
  h = net.hosts;
  bindings = {
    management = false;
    netmgmt = false;
    trusted = true;
    lab = true;
    app = true;
    cluster = true;
  };
  serviceInput = [
    {
      udp.dport = [53 67 547];
      verdict = "accept";
      comment = "DNS and DHCP";
    }
    {
      tcp.dport = 53;
      verdict = "accept";
      comment = "DNS TCP";
    }
  ];
  adminInput =
    serviceInput
    ++ [
      {
        tcp.dport = 22;
        verdict = "accept";
        comment = "Gateway administration";
      }
    ];
  mkVlan = name: dhcp: let
    subnet = net.networks.${name};
  in
    lib.nameValuePair "uplink.${toString subnet.vlanId}" {
      tag = subnet.vlanId;
      network = {
        type = "static";
        addresses = ["${subnet.gateway4}/${toString subnet.prefixLength4}" "${subnet.gateway6}/${toString subnet.prefixLength6}"];
        zone = name;
        dhcp = {
          enable = dhcp;
          reservations = lib.optionals (name == "cluster") (lib.genList (i: let
              host = h."dev-${toString (i + 1)}";
            in {
              mac = "02:51:51:00:00:${lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString (10 + i)))}";
              ip = host.ipv4;
              hostname = "dev-${toString (i + 1)}";
            })
            16);
        };
        dhcp6 = {
          enable = true;
          mode =
            if name == "app"
            then "stateful"
            else "slaac";
          dnsAddress = subnet.gateway6;
        };
      };
    };
  hostFlow = host: ports: comment:
    ds {
      daddr = host;
      tcp.dport = ports;
      verdict = "accept";
      inherit comment;
    };
  adminVPN = ds {
    saddr = {
      ipv4 = net.wireguardNetworks."wg-vpn".subnet4;
      ipv6 = net.wireguardNetworks."wg-vpn".subnet6;
    };
    verdict = "accept";
    comment = "Authenticated operator VPN";
  };
  upstreamFlow = source: host: ports: comment:
    ds {
      saddr = {
        ipv4 = source.subnet4;
        ipv6 = source.subnet6;
      };
      daddr = host;
      tcp.dport = ports;
      verdict = "accept";
      inherit comment;
    };
  # Cluster must not use transit to reach upstream private/VPN networks.
  internetOnly = [
    {
      ip.daddr = ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "169.254.0.0/16" "100.64.0.0/10"];
      verdict = "drop";
    }
    {
      ip6.daddr = ["fc00::/7" "fe80::/10"];
      verdict = "drop";
    }
    {
      verdict = "accept";
      comment = "Cluster public Internet only";
    }
  ];
in {
  router6 = {
    enable = true;
    ulaPrefix = "fdc6:55f2:0a5e::/48";
    topology.uplink = {
      kind = "physical";
      network.type = "disabled";
      vlans =
        builtins.listToAttrs (lib.mapAttrsToList mkVlan bindings)
        // {
          "uplink.255" = {
            tag = net.networks.transit.vlanId;
            network = {
              type = "static";
              addresses = ["${h.bt8gw.cidr4}" "${h.bt8gw.cidr6}"];
              zone = "transit";
            };
          };
        };
    };
    routes = [
      {
        destination = "0.0.0.0/0";
        gateway = net.networks.transit.gateway4;
        interface = "uplink.255";
      }
      {
        destination = "::/0";
        gateway = net.networks.transit.gateway6;
        interface = "uplink.255";
      }
    ];
    dns = {
      upstream = [net.networks.transit.gateway4];
      localDomain = "internal";
      # thebeyond/phantasma validates, including the internal unsigned zone.
      enableDNSSEC = false;
      upstreamPolicy = "stub";
    };
    zones = {
      management = {
        icmpEcho = "enable";
        inputRules = adminInput;
        accessTo = ["trusted" "app" "transit" "netmgmt"];
      };
      trusted = {
        icmpEcho = "enable";
        inputRules = adminInput;
        accessTo = ["management" "lab" "app" "transit" "netmgmt"];
      };
      lab = {
        icmpEcho = "enable";
        inputRules = adminInput;
        accessTo = ["management" "app" "cluster" "transit"];
      };
      netmgmt = {
        icmpEcho = "enable";
        inputRules = serviceInput;
        accessTo = [];
      };
      app = {
        icmpEcho = "enable";
        inputRules = serviceInput;
        accessTo = ["transit"];
        forwardRules.management =
          hostFlow h.basel [443] "APP ACME"
          ++ hostFlow h.tharbad [3100 8427] "APP logging and metrics"
          ++ ds {
            saddr = h.oracion;
            daddr = h.messeldam;
            tcp.dport = 3890;
            verdict = "accept";
            comment = "oracion LDAP";
          };
      };
      cluster = {
        icmpEcho = "enable";
        inputRules = serviceInput;
        forwardRules.app = hostFlow h.creil [22 443] "Cluster Forgejo" ++ hostFlow h.zeiss [443] "Cluster Attic";
        forwardRules.transit = internetOnly;
      };
      transit = {
        icmpEcho = "enable";
        accessTo = [];
        # Permit direct administration of arteria from the operator VPN,
        # without exposing SSH to all traffic arriving over transit.
        inputRules = map (rule: rule // {tcp.dport = 22;}) adminVPN;
        forwardRules = {
          # VPN administration and DMZ service flows arrive with original IPs.
          management =
            adminVPN
            ++ upstreamFlow net.networks.dmz h.basel [443] "DMZ ACME"
            ++ upstreamFlow net.networks.dmz h.tharbad [3100 8427] "DMZ telemetry";
          trusted = adminVPN;
          lab = adminVPN;
          netmgmt = adminVPN;
          app =
            adminVPN
            ++ upstreamFlow net.networks.dmz h.creil [22 443] "DMZ Forgejo"
            ++ upstreamFlow net.networks.dmz h.zeiss [443] "DMZ Attic"
            ++ upstreamFlow net.networks.dmz h.oracion [443] "DMZ media"
            ++ upstreamFlow net.wireguardNetworks."wg-media" h.oracion [443] "Media VPN";
          cluster = adminVPN;
        };
      };
    };
  };
  # router6's zone rules own SSH admission; never open it globally.
  services.openssh.openFirewall = false;
}
