# OpenWrt declarative configuration library
#
# Provides tools for:
# - Building custom OpenWrt images with nix-openwrt-imagebuilder
# - Generating UCI configuration from Nix
# - Managing mesh networking with batman-adv
# - Managing managed switches with VLAN filtering
# - Deploying to devices via SSH/sysupgrade
{lib}: let
  uci = import ./uci.nix {inherit lib;};

  # Packages to remove from default OpenWrt image
  removeDefaultPackages = [
    "-dnsmasq" # We don't run DHCP on mesh APs
    "-odhcpd-ipv6only" # No DHCP
    "-ppp" # No PPPoE
    "-ppp-mod-pppoe"
    "-firewall4" # Mesh APs don't need firewall
    "-nftables"
    "-wpad-basic-mbedtls" # Replaced by mesh-capable wpad
  ];

  # Packages to remove for switch/simple-AP (keep firewall, no mesh wpad)
  removeSwitchPackages = [
    "-dnsmasq"
    "-odhcpd-ipv6only"
    "-ppp"
    "-ppp-mod-pppoe"
  ];

  # Minimal packages required for batman-adv mesh AP
  # Note: 802.1Q VLAN support is built into the kernel in OpenWrt 24.10+
  minimalMeshPackages =
    removeDefaultPackages
    ++ [
      "kmod-batman-adv"
      "batctl-full"
      "wpad-mesh-openssl"
    ];

  # Additional packages for web UI management
  luciPackages = [
    "luci"
    "luci-proto-batman-adv"
  ];

  # Debugging/monitoring tools (optional)
  debugPackages = [
    "htop"
    "tcpdump"
  ];

  # Default: minimal + debug tools (no LuCI)
  defaultMeshPackages = minimalMeshPackages ++ debugPackages;

  # Default packages for a switch
  # Note: 802.1Q VLAN support is built into the kernel in OpenWrt 24.10+
  defaultSwitchPackages = removeSwitchPackages ++ debugPackages;

  # Default packages for a simple AP (keep firewall, no mesh)
  defaultSimpleAPPackages = removeSwitchPackages ++ debugPackages;

  # Generate network configuration for a mesh AP
  # Uses separate bridges per VLAN (matching actual deployed topology)
  mkMeshNetworkConfig = {
    hostname,
    vlans,
    lanAddresses,
    mgmtAddresses,
    gateway,
  }: let
    routingAlgo = "BATMAN_V";
    homeVlan = vlans.HOME or null;
    mgmtVlan = vlans.MGMT or null;

    # br-lan bridges physical LAN ports + bat0.HOME_VLAN
    brLanPorts =
      ["lan2" "lan3" "lan4"]
      ++ lib.optional (homeVlan != null) "bat0.${toString homeVlan.tag}";

    # Derive MGMT gateway from HOME gateway (same last octet, different VLAN subnet)
    mgmtGateway =
      if gateway != null && mgmtVlan != null
      then let
        parts = lib.splitString "." gateway;
      in "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}.${toString mgmtVlan.tag}.${builtins.elemAt parts 3}"
      else null;
  in {
    network =
      {
        # Loopback
        loopback = {
          _type = "interface";
          device = "lo";
          proto = "static";
          ipaddr = "127.0.0.1";
          netmask = "255.0.0.0";
        };

        # batman-adv interface
        bat0 = {
          _type = "interface";
          proto = "batadv";
          routing_algo = routingAlgo;
          aggregated_ogms = true;
          hop_penalty = 30;
          ap_isolation = false;
          bonding = false;
          bridge_loop_avoidance = true;
          distributed_arp_table = true;
          fragmentation = true;
          gw_mode = "off";
          log_level = 0;
          multicast_mode = true;
          multicast_fanout = 16;
          network_coding = false;
          orig_interval = 1000;
        };

        # Wireless mesh hardif
        bat0_mesh0 = {
          _type = "interface";
          proto = "batadv_hardif";
          master = "bat0";
          mtu = 2304;
        };

        # WAN port as wired batman backhaul
        bat0_wan = {
          _type = "interface";
          proto = "batadv_hardif";
          master = "bat0";
          mtu = 1536;
          hop_penalty = 15;
          throughput_override = "1mbit";
          device = "wan";
        };

        # br-lan: LAN ports + HOME VLAN from bat0
        br_lan = {
          _type = "device";
          name = "br-lan";
          type = "bridge";
          ports = brLanPorts;
          stp = true;
          mtu = 1536;
        };

        # LAN interface (HOME network)
        lan =
          {
            _type = "interface";
            device = "br-lan";
            proto =
              if lanAddresses != []
              then "static"
              else "dhcp";
          }
          // lib.optionalAttrs (lanAddresses != []) {
            ipaddr = lanAddresses;
            inherit gateway;
            dns = gateway;
          };
      }
      // lib.optionalAttrs (mgmtVlan != null) {
        # br-mgmt: management VLAN from bat0
        br_mgmt = {
          _type = "device";
          type = "bridge";
          name = "br-mgmt";
          ports = ["bat0.${toString mgmtVlan.tag}"];
          mtu = 1536;
        };

        mgmt =
          {
            _type = "interface";
            proto =
              if mgmtAddresses != []
              then "static"
              else "dhcp";
            device = "br-mgmt";
          }
          // lib.optionalAttrs (mgmtAddresses != []) {
            ipaddr = mgmtAddresses;
            gateway = mgmtGateway;
          };
      }
      // {
        # br-admin: emergency access on lan1
        br_admin = {
          _type = "device";
          type = "bridge";
          name = "br-admin";
          ports = ["lan1"];
        };

        admin = {
          _type = "interface";
          proto = "static";
          device = "br-admin";
          ipaddr = "192.168.1.1";
          netmask = "255.255.255.0";
          gateway = "192.168.1.1";
          dns = "192.168.1.1";
        };
      };
  };

  # Generate wireless configuration for mesh + AP
  # Secret fields (wifi.<name>.ssid, wifi.<name>.key, wifi.mesh.id, wifi.mesh.key) are declared with { _secret = "key"; }
  # markers. They are omitted from the UCI script and injected at build time
  # from the secrets file via merge_secrets_into_uci in the build pipeline.
  mkMeshWirelessConfig = {
    apNetworks,
    country,
    heBssColor,
    legacyRates,
  }: let
    # Generate mesh interface (on 5GHz radio only)
    meshIface = {
      batmesh = {
        _type = "wifi-iface";
        ifname = "batmesh";
        device = "radio1";
        mode = "mesh";
        network = "bat0_mesh0";
        encryption = "sae";
        mesh_fwding = false;
        mesh_id = {_secret = "wifi.mesh.id";};
        key = {_secret = "wifi.mesh.key";};
      };
    };

    # Generate AP interfaces for each network on each radio
    mkAPInterfaces = radio: band:
      lib.mapAttrs' (name: ap: {
        name = "ap_${band}_${name}";
        value = {
          _type = "wifi-iface";
          device = radio;
          mode = "ap";
          network = ap.network or "lan";
          encryption = ap.encryption or "sae-mixed";
          ssid = {_secret = "wifi.${name}.ssid";};
          key = {_secret = "wifi.${name}.key";};
          # 802.11r fast roaming
          ieee80211r = true;
          ft_psk_generate_local = true;
          reassociation_deadline = 20000;
          ft_over_ds = false;
          # BSS transition management
          bss_transition = true;
          wnm_sleep_mode = true;
          time_advertisement = 2;
          time_zone = "GMT0";
          # 802.11k radio resource management
          ieee80211k = true;
          rrm_neighbor_report = true;
          rrm_beacon_report = true;
        };
      })
      apNetworks;
  in {
    wireless =
      {
        radio0 =
          {
            _type = "wifi-device";
            type = "mac80211";
            band = "2g";
            channel = 1;
            htmode = "HT20";
            cell_density = 0;
            inherit country;
            disabled = true;
          }
          // lib.optionalAttrs legacyRates {
            legacy_rates = true;
          };

        radio1 =
          {
            _type = "wifi-device";
            type = "mac80211";
            band = "5g";
            channel = 36;
            htmode = "HE80";
            cell_density = 0;
            inherit country;
            disabled = true;
          }
          // lib.optionalAttrs (heBssColor != null) {
            he_bss_color = heBssColor;
          };
      }
      // meshIface
      // mkAPInterfaces "radio0" "2g"
      // mkAPInterfaces "radio1" "5g";
  };

  # Generate simple AP wireless config (no mesh, no 802.11r)
  mkSimpleAPWirelessConfig = {
    encryption,
    network,
    country,
  }: {
    wireless = {
      radio0 = {
        _type = "wifi-device";
        type = "mac80211";
        band = "2g";
        channel = 1;
        htmode = "HT20";
        cell_density = 0;
        inherit country;
        disabled = true;
      };

      radio1 = {
        _type = "wifi-device";
        type = "mac80211";
        band = "5g";
        channel = 36;
        htmode = "HE80";
        cell_density = 0;
        inherit country;
        disabled = true;
      };

      ap_2g_main = {
        _type = "wifi-iface";
        device = "radio0";
        inherit network;
        mode = "ap";
        inherit encryption;
        ssid = {_secret = "wifi.main.ssid";};
        key = {_secret = "wifi.main.key";};
      };

      ap_5g_main = {
        _type = "wifi-iface";
        device = "radio1";
        inherit network;
        mode = "ap";
        inherit encryption;
        ssid = {_secret = "wifi.main.ssid";};
        key = {_secret = "wifi.main.key";};
      };
    };
  };

  # Generate network config for a managed switch (VLAN-filtering bridge)
  mkSwitchNetworkConfig = {
    hostname,
    lanAddresses,
    gateway,
    vlans,
    trunkPorts,
  }: let
    allPorts = ["lan1" "lan2" "lan3" "lan4" "lan5" "lan6" "lan7" "lan8"];
    portMTU = 1532;

    # Generate per-port MTU device entries
    portDevices = lib.listToAttrs (map (port: {
        name = "port_${port}";
        value = {
          _type = "device";
          name = port;
          mtu = portMTU;
        };
      })
      allPorts);

    # Generate bridge-vlan entries
    bridgeVlanConfigs =
      lib.mapAttrs' (name: vlan: {
        name = "brvlan_${name}";
        value = {
          _type = "bridge-vlan";
          device = "switch";
          vlan = vlan.tag;
          ports =
            map (p: "${p}:t") trunkPorts
            ++ (vlan.accessPorts or []);
        };
      })
      vlans;

    # VLAN device for management interface
    mgmtVlan = vlans.MGMT or (throw "mkSwitchNetworkConfig: MGMT VLAN required");
    lanVlan = vlans.HOME or null;
  in {
    network =
      {
        # Loopback
        loopback = {
          _type = "interface";
          device = "lo";
          proto = "static";
          ipaddr = "127.0.0.1";
          netmask = "255.0.0.0";
        };

        # Main bridge device
        switch = {
          _type = "device";
          name = "switch";
          type = "bridge";
          ports = allPorts;
          mtu = portMTU;
        };

        # LAN bridge combining MGMT and HOME VLANs
        lan_br = {
          _type = "device";
          type = "bridge";
          name = "lan-br";
          ports =
            ["switch.${toString mgmtVlan.tag}"]
            ++ lib.optional (lanVlan != null) "switch.${toString lanVlan.tag}";
          mtu = portMTU;
        };

        # Management interface
        lan = {
          _type = "interface";
          proto = "static";
          device = "lan-br";
          ipaddr = lanAddresses;
          inherit gateway;
          dns = gateway;
        };
      }
      // portDevices // bridgeVlanConfigs;
  };

  # Generate simple AP network config (simple bridge, no batman)
  mkSimpleAPNetworkConfig = {
    hostname,
    lanAddresses,
    gateway,
  }: {
    network = {
      loopback = {
        _type = "interface";
        device = "lo";
        proto = "static";
        ipaddr = "127.0.0.1";
        netmask = "255.0.0.0";
      };

      br_lan = {
        _type = "device";
        name = "br-lan";
        type = "bridge";
        ports = ["lan0" "lan1" "lan2" "lan3"];
      };

      lan =
        {
          _type = "interface";
          device = "br-lan";
          proto =
            if lanAddresses != []
            then "static"
            else "dhcp";
        }
        // lib.optionalAttrs (lanAddresses != []) {
          ipaddr = lanAddresses;
          inherit gateway;
          dns = gateway;
        };
    };
  };

  # Generate system configuration
  mkSystemConfig = {
    hostname,
    timezone,
    log_ip ? null,
  }: {
    system = {
      system =
        {
          _type = "system";
          inherit hostname;
          inherit timezone;
          log_size = 64;
        }
        // lib.optionalAttrs (log_ip != null) {
          inherit log_ip;
          log_proto = "udp";
          log_remote = true;
        };

      ntp = {
        _type = "timeserver";
        enabled = true;
        enable_server = false;
        server = [
          "0.openwrt.pool.ntp.org"
          "1.openwrt.pool.ntp.org"
          "2.openwrt.pool.ntp.org"
          "3.openwrt.pool.ntp.org"
        ];
      };
    };
  };

  # Generate dropbear (SSH) configuration
  mkDropbearConfig = {authorizedKeys}: {
    dropbear = {
      main = {
        _type = "dropbear";
        PasswordAuth =
          if authorizedKeys != []
          then false
          else true;
        RootPasswordAuth =
          if authorizedKeys != []
          then false
          else true;
        Port = 22;
      };
    };
  };

  # Build complete mesh AP configuration
  mkMeshAPConfig = {
    hostname,
    vlans,
    apNetworks,
    lanAddresses,
    mgmtAddresses,
    gateway,
    timezone,
    authorizedKeys,
    country,
    heBssColor,
    legacyRates,
    extraConfig ? {},
  }:
    lib.recursiveUpdate (
      mkSystemConfig {inherit hostname timezone;}
      // mkMeshNetworkConfig {inherit hostname vlans lanAddresses mgmtAddresses gateway;}
      // mkMeshWirelessConfig {inherit apNetworks country heBssColor legacyRates;}
      // mkDropbearConfig {inherit authorizedKeys;}
    )
    extraConfig;

  # Build complete switch configuration
  mkSwitchConfig = {
    hostname,
    lanAddresses,
    gateway,
    vlans,
    trunkPorts,
    timezone,
    authorizedKeys,
    extraConfig ? {},
  }:
    lib.recursiveUpdate (
      mkSystemConfig {inherit hostname timezone;}
      // mkSwitchNetworkConfig {inherit hostname lanAddresses gateway vlans trunkPorts;}
      // mkDropbearConfig {inherit authorizedKeys;}
    )
    extraConfig;

  # Build complete simple AP configuration
  mkSimpleAPConfig = {
    hostname,
    lanAddresses,
    gateway,
    encryption,
    country,
    timezone,
    authorizedKeys,
    extraConfig ? {},
  }:
    lib.recursiveUpdate (
      mkSystemConfig {inherit hostname timezone;}
      // mkSimpleAPNetworkConfig {inherit hostname lanAddresses gateway;}
      // mkSimpleAPWirelessConfig {
        inherit encryption country;
        network = "lan";
      }
      // mkDropbearConfig {inherit authorizedKeys;}
    )
    extraConfig;

  # Generate config files derivation (uci-defaults + authorized_keys)
  # Single function replacing the copy-pasted runCommand blocks in mk*Image
  # Migration pre-commands: delete anonymous sections before creating named ones.
  # On sysupgrade from anonymous → named, this prevents duplicates.
  # Safe no-op on fresh installs (no anonymous sections to delete).
  migrationPreCommands = [
    "# Migration: remove anonymous sections (safe no-op when none exist)"
    "while uci -q delete wireless.@wifi-iface[-1]; do :; done"
    "while uci -q delete firewall.@defaults[-1]; do :; done"
    "while uci -q delete firewall.@zone[-1]; do :; done"
    "while uci -q delete firewall.@forwarding[-1]; do :; done"
    "while uci -q delete firewall.@rule[-1]; do :; done"
    "while uci -q delete system.@system[-1]; do :; done"
    "while uci -q delete dropbear.@dropbear[-1]; do :; done"
    "while uci -q delete dhcp.@dnsmasq[-1]; do :; done"
    "while uci -q delete network.@bridge-vlan[-1]; do :; done"
    "while uci -q delete system.@led[-1]; do :; done"
  ];
in {
  # Re-export UCI library
  inherit uci;

  # High-level API
  inherit
    defaultMeshPackages
    defaultSwitchPackages
    defaultSimpleAPPackages
    mkMeshNetworkConfig
    mkMeshWirelessConfig
    mkSimpleAPWirelessConfig
    mkSwitchNetworkConfig
    mkSimpleAPNetworkConfig
    mkSystemConfig
    mkDropbearConfig
    mkMeshAPConfig
    mkSwitchConfig
    mkSimpleAPConfig
    migrationPreCommands
    ;
}
