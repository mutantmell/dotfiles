# OpenWrt declarative configuration library
#
# Provides tools for:
# - Building custom OpenWrt images with nix-openwrt-imagebuilder
# - Generating UCI configuration from Nix
# - Managing mesh networking with batman-adv
# - Managing managed switches with VLAN filtering
# - Deploying to devices via SSH/sysupgrade
{ lib, openwrt-imagebuilder }:

let
  uci = import ./uci.nix { inherit lib; };

  # Packages to remove from default OpenWrt image
  removeDefaultPackages = [
    "-dnsmasq"          # We don't run DHCP on mesh APs
    "-odhcpd-ipv6only"  # No DHCP
    "-ppp"              # No PPPoE
    "-ppp-mod-pppoe"
    "-firewall4"        # Mesh APs don't need firewall
    "-nftables"
    "-wpad-basic-mbedtls"  # Replaced by mesh-capable wpad
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
  minimalMeshPackages = removeDefaultPackages ++ [
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

  # Packages to remove for router (keep firewall+nftables, dnsmasq, wpad)
  removeRouterPackages = [
    "-odhcpd-ipv6only"
    "-ppp"
    "-ppp-mod-pppoe"
  ];

  # Default packages for a router
  defaultRouterPackages = removeRouterPackages ++ debugPackages;

  # Generate network configuration for a mesh AP
  # Uses separate bridges per VLAN (matching actual deployed topology)
  mkMeshNetworkConfig = {
    hostname,
    meshId,
    routingAlgo ? "BATMAN_V",
    vlans ? {},
    lanAddresses ? [],
    mgmtAddresses ? [],
    gateway ? null,
  }:
    let
      homeVlan = vlans.HOME or null;
      mgmtVlan = vlans.MGMT or null;

      # br-lan bridges physical LAN ports + bat0.HOME_VLAN
      brLanPorts =
        [ "lan2" "lan3" "lan4" ]
        ++ lib.optional (homeVlan != null) "bat0.${toString homeVlan.tag}";

      # Derive MGMT gateway from HOME gateway (same last octet, different VLAN subnet)
      mgmtGateway = if gateway != null && mgmtVlan != null then
        let parts = lib.splitString "." gateway;
        in "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}.${toString mgmtVlan.tag}.${builtins.elemAt parts 3}"
      else null;

    in {
      network = {
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
        lan = {
          _type = "interface";
          device = "br-lan";
          proto = if lanAddresses != [] then "static" else "dhcp";
        } // lib.optionalAttrs (lanAddresses != []) {
          ipaddr = lanAddresses;
          gateway = gateway;
          dns = gateway;
        };

      } // lib.optionalAttrs (mgmtVlan != null) {
        # br-mgmt: management VLAN from bat0
        br_mgmt = {
          _type = "device";
          type = "bridge";
          name = "br-mgmt";
          ports = [ "bat0.${toString mgmtVlan.tag}" ];
          mtu = 1536;
        };

        mgmt = {
          _type = "interface";
          proto = if mgmtAddresses != [] then "static" else "dhcp";
          device = "br-mgmt";
        } // lib.optionalAttrs (mgmtAddresses != []) {
          ipaddr = mgmtAddresses;
          gateway = mgmtGateway;
        };
      } // {
        # br-admin: emergency access on lan1
        br_admin = {
          _type = "device";
          type = "bridge";
          name = "br-admin";
          ports = [ "lan1" ];
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
  mkMeshWirelessConfig = {
    meshId,
    meshKey ? null,
    apNetworks ? {},
    country ? "US",
    heBssColor ? null,
    legacyRates ? false,
  }:
    let
      # Generate mesh interface (on 5GHz radio only)
      meshIface = {
        batmesh = {
          _type = "wifi-iface";
          _anonymous = true;
          ifname = "batmesh";
          device = "radio1";
          mode = "mesh";
          mesh_id = meshId;
          network = "bat0_mesh0";
          encryption = if meshKey != null then "sae" else "none";
          mesh_fwding = false;
        } // lib.optionalAttrs (meshKey != null) {
          key = meshKey;
        };
      };

      # Generate AP interfaces for each network on each radio
      mkAPInterfaces = radio: band: lib.mapAttrs' (name: ap: {
        name = "ap_${band}_${name}";
        value = {
          _type = "wifi-iface";
          _anonymous = true;
          device = radio;
          mode = "ap";
          ssid = ap.ssid;
          network = ap.network or "lan";
          encryption = ap.encryption or "sae-mixed";
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
        } // lib.optionalAttrs (ap ? key) {
          key = ap.key;
        } // lib.optionalAttrs (ap.hidden or false) {
          hidden = true;
        };
      }) apNetworks;

    in {
      wireless = {
        radio0 = {
          _type = "wifi-device";
          type = "mac80211";
          band = "2g";
          channel = 1;
          htmode = "HE40";
          disabled = false;
          cell_density = 0;
          country = country;
        } // lib.optionalAttrs legacyRates {
          legacy_rates = true;
        };

        radio1 = {
          _type = "wifi-device";
          type = "mac80211";
          band = "5g";
          channel = 36;
          htmode = "HE80";
          disabled = false;
          cell_density = 0;
          country = country;
        } // lib.optionalAttrs (heBssColor != null) {
          he_bss_color = heBssColor;
        };
      } // meshIface
        // mkAPInterfaces "radio0" "2g"
        // mkAPInterfaces "radio1" "5g";
    };

  # Generate simple AP wireless config (no mesh, no 802.11r)
  mkSimpleAPWirelessConfig = { ssid, ssidKey ? null, encryption ? "sae-mixed", network ? "lan" }: {
    wireless = {
      radio0 = {
        _type = "wifi-device";
        type = "mac80211";
        band = "2g";
        channel = 1;
        htmode = "HE20";
        disabled = false;
        cell_density = 0;
      };

      radio1 = {
        _type = "wifi-device";
        type = "mac80211";
        band = "5g";
        channel = 36;
        htmode = "HE80";
        disabled = false;
        cell_density = 0;
      };

      ap_2g = {
        _type = "wifi-iface";
        _anonymous = true;
        device = "radio0";
        inherit network;
        mode = "ap";
        inherit ssid encryption;
      } // lib.optionalAttrs (ssidKey != null) { key = ssidKey; };

      ap_5g = {
        _type = "wifi-iface";
        _anonymous = true;
        device = "radio1";
        inherit network;
        mode = "ap";
        inherit ssid encryption;
      } // lib.optionalAttrs (ssidKey != null) { key = ssidKey; };
    };
  };

  # Generate network config for a managed switch (VLAN-filtering bridge)
  mkSwitchNetworkConfig = {
    hostname,
    lanAddresses,
    gateway,
    vlans ? {},
    trunkPorts ? [ "lan1" "lan2" "lan3" "lan4" ],
    accessPorts ? {},
  }:
    let
      allPorts = [ "lan1" "lan2" "lan3" "lan4" "lan5" "lan6" "lan7" "lan8" ];
      portMTU = 1532;

      # Generate per-port MTU device entries
      portDevices = lib.listToAttrs (map (port: {
        name = "port_${port}";
        value = {
          _type = "device";
          name = port;
          mtu = portMTU;
        };
      }) allPorts);

      # Generate bridge-vlan entries
      bridgeVlanConfigs = lib.mapAttrs' (name: vlan: {
        name = "brvlan_${name}";
        value = {
          _type = "bridge-vlan";
          _anonymous = true;
          device = "switch";
          vlan = vlan.tag;
          ports = map (p: "${p}:t") trunkPorts
            ++ (vlan.accessPorts or []);
        };
      }) vlans;

      # VLAN device for management interface
      mgmtVlan = vlans.MGMT or (throw "mkSwitchNetworkConfig: MGMT VLAN required");
      lanVlan = vlans.HOME or null;

    in {
      network = {
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
          ports = [ "switch.${toString mgmtVlan.tag}" ]
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

      } // portDevices // bridgeVlanConfigs;
    };

  # Generate simple AP network config (simple bridge, no batman)
  mkSimpleAPNetworkConfig = { hostname, lanAddresses ? [], gateway ? null }: {
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
        ports = [ "lan0" "lan1" "lan2" "lan3" ];
      };

      lan = {
        _type = "interface";
        device = "br-lan";
        proto = if lanAddresses != [] then "static" else "dhcp";
      } // lib.optionalAttrs (lanAddresses != []) {
        ipaddr = lanAddresses;
        inherit gateway;
        dns = gateway;
      };
    };
  };

  # Generate network configuration for a router (VLAN-filtering bridge + WAN)
  mkRouterNetworkConfig = {
    hostname,
    vlans,
    trunkPorts ? [ "lan2" "lan3" "lan4" ],
    mkGatewayAddresses,
  }:
    let
      # Collect all access ports from all VLANs
      allAccessPorts = lib.concatMap (v: v.accessPorts or []) (builtins.attrValues vlans);
      allBridgePorts = trunkPorts ++ allAccessPorts;

      # Bridge-VLAN entries: trunk ports tagged, access ports untagged+PVID
      bridgeVlanConfigs = lib.mapAttrs' (name: vlan: {
        name = "brvlan_${lib.toLower name}";
        value = {
          _type = "bridge-vlan";
          _anonymous = true;
          device = "br-lan";
          vlan = vlan.tag;
          ports = map (p: "${p}:t") trunkPorts
            ++ map (p: "${p}:u*") (vlan.accessPorts or []);
        };
      }) vlans;

      # Per-VLAN interfaces
      vlanInterfaces = lib.mapAttrs' (name: vlan: {
        name = lib.toLower name;
        value = {
          _type = "interface";
          device = "br-lan.${toString vlan.tag}";
          proto = "static";
          ipaddr = mkGatewayAddresses vlan.tag;
          dns = "127.0.0.1";
        };
      }) vlans;

    in {
      network = {
        # Loopback
        loopback = {
          _type = "interface";
          device = "lo";
          proto = "static";
          ipaddr = "127.0.0.1";
          netmask = "255.0.0.0";
        };

        # WAN interface
        wan = {
          _type = "interface";
          device = "wan";
          proto = "dhcp";
        };

        # Bridge device with VLAN filtering
        br_lan = {
          _type = "device";
          name = "br-lan";
          type = "bridge";
          vlan_filtering = true;
          ports = allBridgePorts;
        };

      } // bridgeVlanConfigs // vlanInterfaces;
    };

  # Generate firewall configuration for a router
  mkRouterFirewallConfig = { vlans }:
    let
      vlanIfaceNames = map lib.toLower (builtins.attrNames vlans);
    in {
      firewall = {
        defaults = {
          _type = "defaults";
          _anonymous = true;
          syn_flood = true;
          input = "REJECT";
          output = "ACCEPT";
          forward = "REJECT";
        };

        zone_wan = {
          _type = "zone";
          _anonymous = true;
          name = "wan";
          network = [ "wan" ];
          input = "REJECT";
          output = "ACCEPT";
          forward = "REJECT";
          masq = true;
          mtu_fix = true;
        };

        zone_lan = {
          _type = "zone";
          _anonymous = true;
          name = "lan";
          network = vlanIfaceNames;
          input = "ACCEPT";
          output = "ACCEPT";
          forward = "ACCEPT";
        };

        fwd_lan_wan = {
          _type = "forwarding";
          _anonymous = true;
          src = "lan";
          dest = "wan";
        };

        rule_wan_dhcp = {
          _type = "rule";
          _anonymous = true;
          name = "Allow-WAN-DHCP";
          src = "wan";
          proto = "udp";
          dest_port = 68;
          target = "ACCEPT";
        };
      };
    };

  # Generate DHCP configuration for a router
  mkRouterDHCPConfig = { vlans }:
    let
      vlanPools = lib.mapAttrs' (name: _vlan: {
        name = lib.toLower name;
        value = {
          _type = "dhcp";
          interface = lib.toLower name;
          start = 100;
          limit = 150;
          leasetime = "12h";
          dhcpv4 = "server";
        };
      }) vlans;
    in {
      dhcp = {
        dnsmasq = {
          _type = "dnsmasq";
          _anonymous = true;
          domainneeded = true;
          boguspriv = true;
          localise_queries = true;
          rebind_protection = true;
          rebind_localhost = true;
          local = "/lan/";
          domain = "lan";
          expandhosts = true;
          authoritative = true;
          readethers = true;
          leasefile = "/tmp/dhcp.leases";
          nonwildcard = true;
          localservice = true;
          ednspacket_max = 1232;
          cachesize = 1000;
        };
      } // vlanPools;
    };

  # Build complete router configuration
  mkRouterConfig = {
    hostname,
    vlans,
    trunkPorts ? [ "lan2" "lan3" "lan4" ],
    mkGatewayAddresses,
    ssid,
    ssidKey ? null,
    encryption ? "sae-mixed",
    timezone ? "America/Los_Angeles",
    authorizedKeys ? [],
    extraConfig ? {},
  }:
    lib.recursiveUpdate (
      mkSystemConfig { inherit hostname timezone; }
      // mkRouterNetworkConfig { inherit hostname vlans trunkPorts mkGatewayAddresses; }
      // mkSimpleAPWirelessConfig { inherit ssid ssidKey encryption; network = "home"; }
      // mkRouterFirewallConfig { inherit vlans; }
      // mkRouterDHCPConfig { inherit vlans; }
      // mkDropbearConfig { inherit authorizedKeys; }
    ) extraConfig;

  # Generate system configuration
  mkSystemConfig = { hostname, timezone ? "UTC", log_ip ? null }:
    {
      system = {
        system = {
          _type = "system";
          _anonymous = true;
          hostname = hostname;
          timezone = timezone;
          log_size = 64;
        } // lib.optionalAttrs (log_ip != null) {
          log_ip = log_ip;
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
  mkDropbearConfig = { authorizedKeys ? [] }:
    {
      dropbear = {
        main = {
          _type = "dropbear";
          _anonymous = true;
          PasswordAuth = if authorizedKeys != [] then false else true;
          RootPasswordAuth = if authorizedKeys != [] then false else true;
          Port = 22;
        };
      };
    };

  # Build complete mesh AP configuration
  mkMeshAPConfig = {
    hostname,
    meshId,
    meshKey ? null,
    vlans ? {},
    apNetworks ? {},
    lanAddresses ? [],
    mgmtAddresses ? [],
    gateway ? null,
    timezone ? "America/Los_Angeles",
    authorizedKeys ? [],
    country ? "US",
    heBssColor ? null,
    legacyRates ? false,
    extraConfig ? {},
  }:
    lib.recursiveUpdate (
      mkSystemConfig { inherit hostname timezone; }
      // mkMeshNetworkConfig { inherit hostname meshId vlans lanAddresses mgmtAddresses gateway; }
      // mkMeshWirelessConfig { inherit meshId meshKey apNetworks country heBssColor legacyRates; }
      // mkDropbearConfig { inherit authorizedKeys; }
    ) extraConfig;

  # Build complete switch configuration
  mkSwitchConfig = {
    hostname,
    lanAddresses,
    gateway,
    vlans ? {},
    trunkPorts ? [ "lan1" "lan2" "lan3" "lan4" ],
    accessPorts ? {},
    timezone ? "UTC",
    authorizedKeys ? [],
    extraConfig ? {},
  }:
    lib.recursiveUpdate (
      mkSystemConfig { inherit hostname timezone; }
      // mkSwitchNetworkConfig { inherit hostname lanAddresses gateway vlans trunkPorts accessPorts; }
      // mkDropbearConfig { inherit authorizedKeys; }
    ) extraConfig;

  # Build complete simple AP configuration
  mkSimpleAPConfig = {
    hostname,
    lanAddresses ? [],
    gateway ? null,
    ssid,
    ssidKey ? null,
    encryption ? "sae-mixed",
    timezone ? "UTC",
    authorizedKeys ? [],
    extraConfig ? {},
  }:
    lib.recursiveUpdate (
      mkSystemConfig { inherit hostname timezone; }
      // mkSimpleAPNetworkConfig { inherit hostname lanAddresses gateway; }
      // mkSimpleAPWirelessConfig { inherit ssid ssidKey encryption; }
      // mkDropbearConfig { inherit authorizedKeys; }
    ) extraConfig;

  # Generate config files derivation (uci-defaults + authorized_keys)
  # Single function replacing the copy-pasted runCommand blocks in mk*Image
  mkConfigFiles = { pkgs, hostname, config, authorizedKeys ? [], extraFiles ? null }:
    pkgs.runCommand "openwrt-config-files-${hostname}" {} ''
      mkdir -p $out/etc/uci-defaults
      mkdir -p $out/etc/dropbear

      cat > $out/etc/uci-defaults/99-nix-config <<'UCIEOF'
      ${uci.mkUCIDefaults { name = "nix-config"; inherit config; }}
      UCIEOF
      chmod +x $out/etc/uci-defaults/99-nix-config

      ${lib.optionalString (authorizedKeys != []) ''
        cat > $out/etc/dropbear/authorized_keys <<'KEYSEOF'
        ${lib.concatStringsSep "\n" authorizedKeys}
        KEYSEOF
        chmod 600 $out/etc/dropbear/authorized_keys
      ''}

      ${lib.optionalString (extraFiles != null) ''
        cp -r ${extraFiles}/* $out/
      ''}
    '';

  # Build an OpenWrt image with the given configuration
  mkImage = { pkgs, profile, config, packages ? [], files ? null, extraImageConfig ? {}, release ? null }:
    let
      profiles = openwrt-imagebuilder.lib.profiles (
        { inherit pkgs; } // lib.optionalAttrs (release != null) { inherit release; }
      );

      # Generate files from config if not provided
      generatedFiles = pkgs.runCommand "openwrt-config-files" {} ''
        mkdir -p $out/etc/uci-defaults
        cat > $out/etc/uci-defaults/99-nix-config <<'EOF'
        ${uci.mkUCIDefaults { name = "nix-config"; inherit config; }}
        EOF
        chmod +x $out/etc/uci-defaults/99-nix-config
      '';

      imageConfig = profiles.identifyProfile profile // {
        inherit packages;
        files = if files != null then files else generatedFiles;
      } // extraImageConfig;

    in openwrt-imagebuilder.lib.build imageConfig;

  # Generate UCI config from a device declaration (pure data with a type field)
  # Dispatches to the appropriate mk*Config function based on device.type
  mkDeviceConfig = { device, owrtData }:
    let
      inherit (owrtData) mkAddresses mkGateway meshVlans switchVlans
                         authorizedKeys defaultAPNetworks meshConfig;
    in
      if device.type == "meshAP" then
        mkMeshAPConfig {
          inherit (device) hostname;
          inherit (meshConfig) meshId;
          inherit authorizedKeys;
          vlans = meshVlans;
          apNetworks = defaultAPNetworks;
          lanAddresses = mkAddresses meshVlans.HOME.tag device.hostId;
          mgmtAddresses = mkAddresses meshVlans.MGMT.tag device.hostId;
          gateway = mkGateway meshVlans.HOME.tag;
          timezone = device.timezone or "America/Los_Angeles";
          country = device.country or "US";
          heBssColor = device.heBssColor or null;
          legacyRates = device.legacyRates or false;
          extraConfig = device.extraConfig or {};
        }
      else if device.type == "switch" then
        mkSwitchConfig {
          inherit (device) hostname;
          inherit authorizedKeys;
          lanAddresses = mkAddresses device.vlanId device.hostId;
          gateway = mkGateway device.vlanId;
          vlans = switchVlans;
          extraConfig = device.extraConfig or {};
        }
      else if device.type == "simpleAP" then
        mkSimpleAPConfig {
          inherit (device) hostname ssid;
          inherit authorizedKeys;
          lanAddresses = mkAddresses device.vlanId device.hostId;
          gateway = mkGateway device.vlanId;
          ssidKey = device.ssidKey or null;
          encryption = device.encryption or "sae-mixed";
          extraConfig = device.extraConfig or {};
        }
      else if device.type == "router" then
        mkRouterConfig {
          inherit (device) hostname ssid;
          inherit authorizedKeys;
          vlans = owrtData.routerVlans;
          mkGatewayAddresses = owrtData.mkGatewayAddresses;
          trunkPorts = device.trunkPorts or [ "lan2" "lan3" "lan4" ];
          ssidKey = device.ssidKey or null;
          encryption = device.encryption or "sae-mixed";
          timezone = device.timezone or "America/Los_Angeles";
          extraConfig = device.extraConfig or {};
        }
      else throw "mkDeviceConfig: unknown device type '${device.type}'";

  # Build an image from a device declaration
  # Single entry point: declaration -> config -> files -> image
  mkDeviceImage = { pkgs, device, owrtData }:
    let
      config = mkDeviceConfig { inherit device owrtData; };
      inherit (device) hostname profile;
      release = device.release or owrtData.defaultRelease or null;
      extraPackages = device.extraPackages or [];
      extraFiles = device.extraFiles or null;
      inherit (owrtData) authorizedKeys;
      packages =
        if device.type == "meshAP" then defaultMeshPackages ++ extraPackages
        else if device.type == "switch" then defaultSwitchPackages ++ extraPackages
        else if device.type == "simpleAP" then defaultSimpleAPPackages ++ extraPackages
        else if device.type == "router" then defaultRouterPackages ++ extraPackages
        else throw "mkDeviceImage: unknown device type '${device.type}'";
    in mkImage {
      inherit pkgs profile config packages release;
      files = mkConfigFiles { inherit pkgs hostname config authorizedKeys extraFiles; };
    };

in {
  # Re-export UCI library
  inherit uci;

  # Package sets (for customization)
  packages = {
    inherit
      removeDefaultPackages
      removeSwitchPackages
      removeRouterPackages
      minimalMeshPackages
      luciPackages
      debugPackages
      defaultMeshPackages
      defaultSwitchPackages
      defaultSimpleAPPackages
      defaultRouterPackages;
  };

  # High-level API
  inherit
    defaultMeshPackages
    defaultSwitchPackages
    defaultSimpleAPPackages
    defaultRouterPackages
    mkMeshNetworkConfig
    mkMeshWirelessConfig
    mkSimpleAPWirelessConfig
    mkSwitchNetworkConfig
    mkSimpleAPNetworkConfig
    mkRouterNetworkConfig
    mkRouterFirewallConfig
    mkRouterDHCPConfig
    mkRouterConfig
    mkSystemConfig
    mkDropbearConfig
    mkMeshAPConfig
    mkSwitchConfig
    mkSimpleAPConfig
    mkConfigFiles
    mkImage
    mkDeviceConfig
    mkDeviceImage;
}
