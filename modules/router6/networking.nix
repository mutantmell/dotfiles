{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.router6;
  r6lib = import ./lib.nix {inherit cfg lib;};

  inherit
    (lib)
    mapAttrs
    mapAttrsToList
    filterAttrs
    concatMapAttrs
    optionalAttrs
    filter
    ;
  inherit (builtins) attrNames length;
  inherit
    (r6lib)
    devicesByKind
    isMember
    findContaining
    flattenTopology
    raInterfaces
    getEffectiveAddresses
    parseCIDR
    isV6
    ;
in {
  config = lib.mkIf cfg.enable (lib.mkMerge [
    # ===================
    # Basic System Config
    # ===================
    {
      boot.kernel.sysctl =
        {
          # Routing
          "net.ipv4.conf.all.forwarding" = true;
          "net.ipv6.conf.all.forwarding" = true;
          "net.ipv4.conf.default.rp_filter" = 1;
          "net.ipv4.conf.all.rp_filter" = 1;

          # Accept RAs on external interface even when forwarding
          "net.ipv6.conf.all.accept_ra" = 0;
          "net.ipv6.conf.default.accept_ra" = 0;

          # ICMP redirect hardening — router must not send or accept redirects
          "net.ipv4.conf.all.send_redirects" = 0;
          "net.ipv4.conf.default.send_redirects" = 0;
          "net.ipv4.conf.all.accept_redirects" = 0;
          "net.ipv4.conf.default.accept_redirects" = 0;
          "net.ipv6.conf.all.accept_redirects" = 0;
          "net.ipv6.conf.default.accept_redirects" = 0;

          # Log martian packets (spoofed/impossible source addresses)
          "net.ipv4.conf.all.log_martians" = 1;
          "net.ipv4.conf.default.log_martians" = 1;

          # Kernel hardening
          "dev.tty.ldisc_autoload" = 0;
          "fs.protected_fifos" = 2;
          "fs.protected_regular" = 2;
          "fs.suid_dumpable" = 0;
          "kernel.kptr_restrict" = 2;
          "kernel.sysrq" = 0;
          "net.core.bpf_jit_harden" = 2;
        }
        // lib.listToAttrs (map (iface: {
            name = "net.ipv6.conf.${iface}.accept_ra";
            value = 2;
          })
          raInterfaces);

      networking = {
        useDHCP = false;
        firewall.enable = false; # We use nftables directly
      };

      systemd.network.enable = true;
      # Disable systemd-networkd-wait-online for routers.  A router has both
      # DHCP WAN (lease arrives late) and static LAN interfaces.  When the
      # WAN lease arrives, networkd re-triggers network-online.target, which
      # puts kea's start job into "waiting" indefinitely.  A router must
      # serve LAN DHCP independently of WAN state, so there is no meaningful
      # "network is online" moment to wait for.
      systemd.network.wait-online.enable = false;
      services.resolved.enable = false; # We use kresd

      environment.systemPackages = with pkgs; [
        tcpdump
        conntrack-tools
        ethtool
        dig
      ];
    }

    # ========================
    # systemd-networkd: Links
    # ========================
    {
      systemd.network.links = lib.listToAttrs (filter (x: x != null) (
        mapAttrsToList (
          name: iface:
            if iface.mac != null
            then {
              name = "00-${name}";
              value = {
                matchConfig.MACAddress = iface.mac;
                matchConfig.Type = "ether";
                linkConfig.Name = name;
              };
            }
            else if iface.hardwareName != null
            then {
              name = "00-${name}";
              value = {
                matchConfig.OriginalName = iface.hardwareName;
                linkConfig.Name = name;
              };
            }
            else null
        )
        cfg.topology
      ));
    }

    # ==========================
    # systemd-networkd: Netdevs
    # ==========================
    {
      systemd.network.netdevs = let
        # Bond netdevs (from topology) - 01- prefix (early, can be batman members)
        bondDevs = mapAttrs (name: device: {
          name = "01-${name}";
          value = {
            netdevConfig = {
              Name = name;
              Kind = "bond";
            };
            bondConfig =
              {
                Mode = device.mode;
                MIIMonitorSec = device.miiMonitorSec or "100ms";
              }
              // optionalAttrs (device.mode == "802.3ad") {
                LACPTransmitRate = device.lacpTransmitRate or "fast";
              };
          };
        }) (devicesByKind "bond");

        # Bridge netdevs (from topology) - 03- prefix (after bonds/batman, before VLANs)
        bridgeDevs = mapAttrs (name: device: {
          name = "03-${name}";
          value = {
            netdevConfig = {
              Name = name;
              Kind = "bridge";
            };
          };
        }) (devicesByKind "bridge");

        # VLAN netdevs - 04- prefix (after all potential parent netdevs, before any network files)
        vlanDevs =
          concatMapAttrs (
            parentName: parent:
              mapAttrs (vlanName: vlan: {
                name = "04-${vlanName}";
                value = {
                  netdevConfig = {
                    Name = vlanName;
                    Kind = "vlan";
                  };
                  vlanConfig.Id = vlan.tag;
                };
              }) (parent.vlans or {})
          )
          cfg.topology;

        # Batman netdevs - 02- prefix (after bonds, can use bonds as members)
        batmanDevs = filterAttrs (n: v: v != null) (mapAttrs (
            name: iface:
              if iface.batman != null
              then {
                name = "02-${name}";
                value = {
                  netdevConfig = {
                    Name = name;
                    Kind = "batadv";
                  };
                  batmanAdvancedConfig = {
                    GatewayMode = iface.batman.gatewayMode;
                    RoutingAlgorithm = iface.batman.routingAlgorithm;
                  };
                };
              }
              else null
          )
          cfg.topology);

        # Wireguard netdevs - 30- prefix
        wgDevs = filterAttrs (n: v: v != null) (mapAttrs (
            name: iface:
              if iface.wireguard != null
              then {
                name = "30-${name}";
                value = {
                  netdevConfig = {
                    Name = name;
                    Kind = "wireguard";
                  };
                  wireguardConfig =
                    {
                      PrivateKeyFile = iface.wireguard.privateKeyFile;
                    }
                    // optionalAttrs (iface.wireguard.port != null) {
                      ListenPort = iface.wireguard.port;
                    };
                  wireguardPeers = map (peer:
                    {
                      PublicKey = peer.publicKey;
                      AllowedIPs = peer.allowedIPs;
                    }
                    // optionalAttrs (peer.endpoint != null) {
                      Endpoint = peer.endpoint;
                    }
                    // optionalAttrs (peer.persistentKeepalive != null) {
                      PersistentKeepalive = peer.persistentKeepalive;
                    })
                  iface.wireguard.peers;
                };
              }
              else null
          )
          cfg.topology);
      in
        lib.listToAttrs (
          mapAttrsToList (n: v: v) (bondDevs // bridgeDevs // vlanDevs // batmanDevs // wgDevs)
        );
    }

    # ============================
    # systemd-networkd: Networks
    # ============================
    {
      systemd.network.networks = let
        mkNetworkConfig = name: ifaceData: {
          network,
          kind,
          vlans ? {},
          ...
        }: let
          # Build membership config by merging all applicable memberships
          membershipConfig =
            (
              if kind == "physical" && isMember "bond" name
              then {Bond = findContaining "bond" name;}
              else {}
            )
            // (
              if (kind == "physical" || kind == "bond") && isMember "batman" name
              then {BatmanAdvanced = findContaining "batman" name;}
              else {}
            )
            // (
              if isMember "bridge" name
              then {Bridge = findContaining "bridge" name;}
              else {}
            );

          # Get effective addresses as parsed objects (including auto-generated IPv6)
          effectiveAddrs =
            if ifaceData != null
            then getEffectiveAddresses ifaceData
            else map parseCIDR (network.addresses or []);
          # Check if this interface should send Router Advertisements
          # Driven by explicit options, not by type
          shouldSendRA = (network.dhcp6.enable or false) || (network.pdSubnetId or null) != null;
          # Get IPv6 addresses for RA prefix configuration
          v6Addrs = filter isV6 effectiveAddrs;
        in
          {
            matchConfig.Name = name;

            # Static addresses (NixOS uses top-level 'address' list, not networkConfig.Address)
            address =
              if network.type == "static"
              then map (a: a.cidr) effectiveAddrs
              else [];

            networkConfig =
              {
                DHCP =
                  if network.type == "dhcp"
                  then "yes"
                  else "no";
                IPv6AcceptRA = network.type == "dhcp" || (network.ipv6PrefixDelegation.enable or false);
                LinkLocalAddressing =
                  if network.type == "disabled"
                  then "no"
                  else if network.type == "dhcp"
                  then "yes"
                  else "ipv6";
              }
              // optionalAttrs (network.type == "static" && length effectiveAddrs > 0) {
                # Address = effectiveAddrs;
              }
              // optionalAttrs (network.gateway != null) {
                Gateway = network.gateway;
              }
              // optionalAttrs (length network.dns > 0) {
                DNS = network.dns;
              }
              // optionalAttrs shouldSendRA {
                # Enable Router Advertisement on interfaces with dhcp6 enabled
                IPv6SendRA = true;
              }
              // optionalAttrs ((network.pdSubnetId or null) != null) {
                # Receive delegated /64 from WAN PD pool
                DHCPPrefixDelegation = true;
              }
              // membershipConfig; # Merge membership settings (Bond=, BatmanAdvanced=, Bridge=)

            linkConfig =
              {
                RequiredForOnline =
                  if network.required
                  then "routable"
                  else "no";
              }
              // optionalAttrs (network.mtu != null) {
                MTUBytes = toString network.mtu;
              };
          }
          // optionalAttrs shouldSendRA {
            # IPv6 Router Advertisement configuration
            ipv6SendRAConfig = let
              dhcp6Mode = network.dhcp6.mode or "slaac";
            in
              {
                # RA flags control whether clients use DHCPv6:
                # slaac:     M=0, O=0 — SLAAC only, no DHCPv6
                # stateless: M=0, O=1 — SLAAC for addresses, DHCPv6 for DNS/options
                # stateful:  M=1, O=0 — DHCPv6 for addresses, SLAAC still runs for privacy
                Managed = dhcp6Mode == "stateful";
                OtherInformation = dhcp6Mode == "stateless";
                RouterLifetimeSec = 1800;
              }
              // optionalAttrs ((network.dhcp6.dnsAddress or null) != null) {
                # Advertise explicitly configured DNS server address in RAs
                EmitDNS = true;
                DNS = network.dhcp6.dnsAddress;
              };

            # Advertise static IPv6 prefixes for SLAAC (ULA)
            # Delegated prefixes are announced automatically by DHCPPrefixDelegation
            ipv6Prefixes =
              map (addr: {
                Prefix = "${addr.networkPrefix}/${toString addr.prefix}";
                PreferredLifetimeSec = 3600;
                ValidLifetimeSec = 7200;
              })
              v6Addrs;
          }
          // optionalAttrs (network.ipv6PrefixDelegation.enable or false) {
            # DHCPv6-PD client: request delegated prefix from ISP
            dhcpV6Config = {
              PrefixDelegationHint = "::/${toString network.ipv6PrefixDelegation.prefixLength}";
              # Always send DHCPv6 solicits, even if ISP RA doesn't set M flag
              WithoutRA = "solicit";
              # Don't use ISP-provided DNS — we run our own resolver
              UseDNS = false;
              UseHostname = false;
            };
          }
          // optionalAttrs ((network.pdSubnetId or null) != null) {
            # Receive a /64 from the delegated prefix pool
            dhcpPrefixDelegationConfig = {
              SubnetId = network.pdSubnetId;
              Token = "::1";
              Announce = true;
              Assign = true;
            };
          }
          // optionalAttrs (vlans != {}) {
            # Add VLAN list if device has VLANs
            vlan = attrNames vlans;
          };

        # Determine numeric prefix for a device network
        # 10- for regular devices, 40- for wireguard
        devicePrefix = device:
          if device.kind == "wireguard"
          then "40-"
          else "10-";

        # Physical and virtual device networks
        deviceNetworks =
          mapAttrs (name: device: {
            name = "${devicePrefix device}${name}";
            value = mkNetworkConfig name (lib.findFirst (i: i.name == name) null flattenTopology) device;
          })
          cfg.topology;

        # VLAN networks - 21- prefix
        vlanNetworks =
          concatMapAttrs (
            parentName: parent:
              mapAttrs (
                vlanName: vlan: let
                  ifaceData = lib.findFirst (i: i.name == vlanName) null flattenTopology;

                  # Bridged VLAN: attach to bridge, no own IP config
                  bridgedVlan = {
                    name = "21-${vlanName}";
                    value = {
                      matchConfig.Name = vlanName;
                      networkConfig.Bridge = findContaining "bridge" vlanName;
                      linkConfig.RequiredForOnline = "no";
                    };
                  };

                  # Standalone VLAN: has own network config
                  standaloneVlan = {
                    name = "21-${vlanName}";
                    value = mkNetworkConfig vlanName ifaceData {
                      inherit (vlan) network;
                      kind = "vlan";
                    };
                  };
                in
                  if isMember "bridge" vlanName
                  then bridgedVlan
                  else standaloneVlan
              ) (parent.vlans or {})
          )
          cfg.topology;
      in
        lib.listToAttrs (
          mapAttrsToList (n: v: v) (deviceNetworks // vlanNetworks)
        );
    }
  ]);
}
