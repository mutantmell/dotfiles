# OpenWrt declarative configuration library
#
# Provides tools for:
# - Building custom OpenWrt images with nix-openwrt-imagebuilder
# - Generating UCI configuration from Nix
# - Managing mesh networking with batman-adv
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

  # Minimal packages required for batman-adv mesh AP
  # This is the smallest functional set for declarative management via SSH
  minimalMeshPackages = removeDefaultPackages ++ [
    # batman-adv mesh networking
    "kmod-batman-adv"
    "batctl-full"

    # Wireless mesh support (openssl variant supports mesh + WPA3)
    "wpad-mesh-openssl"

    # VLAN support for network segmentation
    "kmod-8021q"
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

  # Generate network configuration for a mesh AP
  mkMeshNetworkConfig = { hostname, meshId, routingAlgo ? "BATMAN_V", vlans ? {}, lanAddress ? null }:
    let
      # Generate VLAN interface configs
      vlanInterfaces = lib.mapAttrs' (name: vlan: {
        name = "vlan_${name}";
        value = {
          _type = "interface";
          device = "bat0.${toString vlan.tag}";
          proto = "none";
        };
      }) vlans;

      # Generate VLAN devices on bat0
      vlanDevices = lib.mapAttrs' (name: vlan: {
        name = "bat0_${name}";
        value = {
          _type = "device";
          type = "8021q";
          name = "bat0.${toString vlan.tag}";
          ifname = "bat0";
          vid = vlan.tag;
        };
      }) vlans;

      # Generate bridge-vlan mappings for each VLAN
      bridgeVlanConfigs = lib.mapAttrs' (name: vlan: {
        name = "brvlan_${name}";
        value = {
          _type = "bridge-vlan";
          _anonymous = true;
          device = "br-lan";
          vlan = vlan.tag;
          ports = [ "lan*:t" "bat0:t" ];  # Tagged on all LAN ports and bat0
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

        # batman-adv interface
        bat0 = {
          _type = "interface";
          proto = "batadv";
          routing_algo = routingAlgo;
          gw_mode = "client";
          orig_interval = 1000;
        };

        # Bridge device config
        br_lan = {
          _type = "device";
          name = "br-lan";
          type = "bridge";
          ports = [ "lan1" "lan2" "lan3" "lan4" "bat0" ];
          # Enable VLAN filtering on bridge
          vlan_filtering = true;
        };

        # LAN interface (management)
        lan = {
          _type = "interface";
          device = "br-lan";
          proto = if lanAddress != null then "static" else "dhcp";
        } // lib.optionalAttrs (lanAddress != null) {
          ipaddr = lanAddress;
          netmask = "255.255.255.0";
        };

      } // vlanInterfaces // vlanDevices // bridgeVlanConfigs;
    };

  # Generate wireless configuration for mesh + AP
  mkMeshWirelessConfig = { meshId, meshKey ? null, apNetworks ? {} }:
    let
      # Generate mesh interface for each radio
      mkMeshIface = radio: band: {
        "mesh_${band}" = {
          _type = "wifi-iface";
          _anonymous = true;
          device = radio;
          mode = "mesh";
          mesh_id = meshId;
          network = "bat0";
          encryption = if meshKey != null then "sae" else "none";
        } // lib.optionalAttrs (meshKey != null) {
          key = meshKey;
        };
      };

      # Generate AP interfaces for each network
      mkAPInterfaces = radio: band: lib.mapAttrs' (name: ap: {
        name = "ap_${band}_${name}";
        value = {
          _type = "wifi-iface";
          _anonymous = true;
          device = radio;
          mode = "ap";
          ssid = ap.ssid;
          network = ap.network or "lan";
          encryption = ap.encryption or "psk2";
        } // lib.optionalAttrs (ap.key or null != null) {
          key = ap.key;
        } // lib.optionalAttrs (ap.hidden or false) {
          hidden = true;
        };
      }) apNetworks;

    in {
      wireless = {
        # Disable default radios until configured
        radio0 = {
          _type = "wifi-device";
          type = "mac80211";
          band = "2g";
          channel = "auto";
          htmode = "HE40";
          disabled = false;
        };

        radio1 = {
          _type = "wifi-device";
          type = "mac80211";
          band = "5g";
          channel = "auto";
          htmode = "HE80";
          disabled = false;
        };
      } // mkMeshIface "radio0" "2g"
        // mkMeshIface "radio1" "5g"
        // mkAPInterfaces "radio0" "2g"
        // mkAPInterfaces "radio1" "5g";
    };

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
    lanAddress ? null,
    timezone ? "America/Los_Angeles",
    authorizedKeys ? [],
    extraConfig ? {},
  }:
    lib.recursiveUpdate (
      mkSystemConfig { inherit hostname timezone; }
      // mkMeshNetworkConfig { inherit hostname meshId vlans lanAddress; }
      // mkMeshWirelessConfig { inherit meshId meshKey apNetworks; }
      // mkDropbearConfig { inherit authorizedKeys; }
    ) extraConfig;

  # Build an OpenWrt image with the given configuration
  mkImage = { pkgs, profile, config, packages ? [], files ? null, extraImageConfig ? {} }:
    let
      profiles = openwrt-imagebuilder.lib.profiles { inherit pkgs; };

      # Generate files from config if not provided
      generatedFiles = pkgs.runCommand "openwrt-config-files" {} ''
        mkdir -p $out/etc/uci-defaults
        cat > $out/etc/uci-defaults/99-nix-config <<'EOF'
        ${uci.mkUCIDefaults { name = "nix-config"; inherit config; }}
        EOF
        chmod +x $out/etc/uci-defaults/99-nix-config
      '';

      imageConfig = profiles.identifyProfile profile // {
        packages = defaultMeshPackages ++ packages;
        files = if files != null then files else generatedFiles;
      } // extraImageConfig;

    in openwrt-imagebuilder.lib.build imageConfig;

  # Build image with SSH key setup
  mkMeshAPImage = {
    pkgs,
    profile,
    hostname,
    meshId,
    meshKey ? null,
    vlans ? {},
    apNetworks ? {},
    lanAddress ? null,
    timezone ? "America/Los_Angeles",
    authorizedKeys ? [],
    extraPackages ? [],
    extraConfig ? {},
    extraFiles ? null,
  }:
    let
      config = mkMeshAPConfig {
        inherit hostname meshId meshKey vlans apNetworks lanAddress timezone authorizedKeys extraConfig;
      };

      # Create files with SSH keys
      configFiles = pkgs.runCommand "openwrt-config-files-${hostname}" {} ''
        mkdir -p $out/etc/uci-defaults
        mkdir -p $out/etc/dropbear

        # UCI defaults script
        cat > $out/etc/uci-defaults/99-nix-config <<'UCIEOF'
        ${uci.mkUCIDefaults { name = "nix-config"; inherit config; }}
        UCIEOF
        chmod +x $out/etc/uci-defaults/99-nix-config

        # Authorized keys
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

    in mkImage {
      inherit pkgs profile config;
      packages = extraPackages;
      files = configFiles;
    };

in {
  # Re-export UCI library
  inherit uci;

  # Package sets (for customization)
  packages = {
    inherit
      removeDefaultPackages
      minimalMeshPackages
      luciPackages
      debugPackages
      defaultMeshPackages;
  };

  # High-level API
  inherit
    defaultMeshPackages
    mkMeshNetworkConfig
    mkMeshWirelessConfig
    mkSystemConfig
    mkDropbearConfig
    mkMeshAPConfig
    mkImage
    mkMeshAPImage;
}
