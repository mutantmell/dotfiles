# OpenWrt device configurations
#
# Each device is defined with its hardware profile, network settings,
# and mesh configuration. Images are built using nix-openwrt-imagebuilder.
#
# SECRETS: Wifi/mesh passwords are NOT included in images (would expose them
# in nix store). Instead, secrets are configured post-deployment via SSH.
# Create hosts/openwrt/secrets/wifi.yaml with: sops hosts/openwrt/secrets/wifi.yaml
#
# Build an image:
#   nix build .#openwrtImages.<device-name>
#
# Deploy to device (includes secrets configuration):
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
#
# Configure secrets on existing device:
#   nix run .#openwrt-configure-secrets -- <device-ip>
{ lib, pkgs, openwrt }:

let
  # Import common data
  data = import ../../lib/common/data;

  # Shared mesh configuration matching yggdrasil's batman-adv setup
  # Note: meshKey is intentionally omitted - configured via secrets post-deployment
  meshConfig = {
    # Override with actual mesh ID before building
    meshId = "change-me-mesh-id";
  };

  # IP prefixes — each device gets one address per prefix for migration compatibility
  ipPrefixes = [ "10.0" "10.1" "10.97" ];

  # Generate list of CIDR addresses for a given VLAN and host ID across all prefixes
  mkAddresses = vlanId: hostId:
    map (p: "${p}.${toString vlanId}.${toString hostId}/24") ipPrefixes;

  # Gateway is always on the primary prefix (10.0)
  mkGateway = vlanId: "10.0.${toString vlanId}.1";

  # VLANs matching actual deployed configuration
  # Mesh APs use 10xx tags on bat0 (bat0.1010, bat0.1020, etc.)
  meshVlans = {
    MGMT = { tag = 10; };
    HOME = { tag = 20; };
  };

  # Switch VLANs — denali uses standard VLAN tags on a bridge
  # Trunk ports (lan1-4) carry all VLANs tagged; access ports are untagged
  switchVlans = {
    MGMT     = { tag = 10; accessPorts = [ "lan7" "lan8" ]; };
    HOME     = { tag = 20; accessPorts = [ "lan5" "lan6" ]; };
    GUEST    = { tag = 30; };
    ADU      = { tag = 31; };
    IOT      = { tag = 40; };
    GAME     = { tag = 41; };
    MEDIA    = { tag = 42; };
    DMZ      = { tag = 100; };
  };

  # SSH authorized keys for deployment
  authorizedKeys = [
    data.keys.ssh.deploy
    data.keys.ssh.home
  ];

  # Common AP networks (can be overridden per-device)
  # Note: Keys are intentionally omitted - configured via secrets post-deployment
  # The deploy script matches networks by SSID pattern to apply keys
  defaultAPNetworks = {
    main = {
      # Override with actual SSIDs before building
      ssid = "MyNetwork";
      network = "lan";
      encryption = "sae-mixed";
    };
    secondary = {
      ssid = "MyNetwork-Alt";
      network = "lan";
      encryption = "sae-mixed";
    };
  };

  # Helper to create a mesh AP configuration
  mkMeshAP = {
    hostname,
    profile,
    hostId,
    heBssColor ? null,
    legacyRates ? false,
    extraPackages ? [],
    extraConfig ? {},
  }:
    openwrt.mkMeshAPImage {
      inherit pkgs profile hostname heBssColor legacyRates extraPackages extraConfig;
      inherit (meshConfig) meshId;
      inherit authorizedKeys;
      lanAddresses = mkAddresses meshVlans.HOME.tag hostId;
      mgmtAddresses = mkAddresses meshVlans.MGMT.tag hostId;
      gateway = mkGateway meshVlans.HOME.tag;
      vlans = meshVlans;
      apNetworks = defaultAPNetworks;
      timezone = "America/Los_Angeles";
      country = "US";
    };

  # Helper to create a managed switch configuration
  mkSwitch = {
    hostname,
    profile,
    hostId,
    vlanId,
    extraPackages ? [],
    extraConfig ? {},
  }:
    openwrt.mkSwitchImage {
      inherit pkgs profile hostname extraPackages extraConfig;
      inherit authorizedKeys;
      lanAddresses = mkAddresses vlanId hostId;
      gateway = mkGateway vlanId;
      vlans = switchVlans;
    };

  # Helper to create a simple AP configuration
  mkSimpleAP = {
    hostname,
    profile,
    hostId,
    vlanId,
    ssid,
    ssidKey ? null,
    encryption ? "sae-mixed",
    extraPackages ? [],
    extraConfig ? {},
  }:
    openwrt.mkSimpleAPImage {
      inherit pkgs profile hostname ssid ssidKey encryption
              extraPackages extraConfig;
      inherit authorizedKeys;
      lanAddresses = mkAddresses vlanId hostId;
      gateway = mkGateway vlanId;
    };

in {
  # =============================================================================
  # Mesh APs — batman-adv mesh, 802.11r/k roaming, wired backhaul
  # All Linksys E8450 (UBI variant)
  # =============================================================================

  goo = mkMeshAP {
    hostname = "goo";
    profile = "linksys_e8450-ubi";
    hostId = 23;
    heBssColor = 49;
  };

  gumbo = mkMeshAP {
    hostname = "gumbo";
    profile = "linksys_e8450-ubi";
    hostId = 24;
    heBssColor = 58;
    extraPackages = [ "usteer" ];
  };

  gumby = mkMeshAP {
    hostname = "gumby";
    profile = "linksys_e8450-ubi";
    hostId = 20;
    heBssColor = 8;
    legacyRates = true;
    extraPackages = [ "usteer" ];
  };

  pokey = mkMeshAP {
    hostname = "pokey";
    profile = "linksys_e8450-ubi";
    hostId = 21;
    heBssColor = 25;
    legacyRates = true;
    extraPackages = [ "usteer" ];
    extraConfig = {
      # IoT VLAN — additional bat0.1040 interface with IoT SSID
      network = {
        iot = {
          _type = "interface";
          proto = "static";
          device = "bat0.1040";
          ipaddr = mkAddresses 40 21;
          gateway = mkGateway 40;
          dns = mkGateway 40;
          type = "bridge";
        };
      };
      wireless = {
        ap_2g_iot = {
          _type = "wifi-iface";
          _anonymous = true;
          device = "radio0";
          mode = "ap";
          ssid = "MyNetwork-IoT";
          encryption = "sae-mixed";
          network = "iot";
        };
      };
    };
  };

  prickle = mkMeshAP {
    hostname = "prickle";
    profile = "linksys_e8450-ubi";
    hostId = 22;
    heBssColor = 8;
    extraPackages = [ "usteer" ];
  };

  # =============================================================================
  # Managed Switch — VLAN-filtering bridge, no batman-adv
  # NETGEAR GS108T v3
  # =============================================================================

  denali = mkSwitch {
    hostname = "denali";
    profile = "netgear_gs108t-v3";
    hostId = 12;
    vlanId = 10;
    extraPackages = openwrt.packages.luciPackages;
  };

  # =============================================================================
  # ADU Router/AP — provides segmented internet access for an ADU
  # Runs firewall + DHCP/DHCPv6/RA, no mesh, no batman-adv
  # TP-Link EAP615-Wall v1 (UNCONFIRMED: verify before deploying)
  # =============================================================================

  gumba = mkSimpleAP {
    hostname = "gumba";
    profile = "tplink_eap615-wall-v1";  # UNCONFIRMED: verify before deploying
    hostId = 20;
    vlanId = 31;
    ssid = "MyAP";
    # Keep dnsmasq (removed by default) — gumba serves DHCP for the ADU network
    extraPackages = [ "dnsmasq" "odhcpd-ipv6only" ];
    extraConfig = {
      # Firewall — stricter defaults than mesh APs (acts as a gateway)
      firewall = {
        defaults = {
          _type = "defaults";
          _anonymous = true;
          syn_flood = true;
          input = "REJECT";
          output = "ACCEPT";
          forward = "REJECT";
        };
        zone_lan = {
          _type = "zone";
          _anonymous = true;
          name = "lan";
          input = "ACCEPT";
          output = "ACCEPT";
          forward = "ACCEPT";
        };
        zone_wan = {
          _type = "zone";
          _anonymous = true;
          name = "wan";
          network = [ "wan" "wan6" ];
          input = "REJECT";
          output = "ACCEPT";
          forward = "REJECT";
          masq = true;
          mtu_fix = true;
        };
        fwd_lan_wan = {
          _type = "forwarding";
          _anonymous = true;
          src = "lan";
          dest = "wan";
        };
      };

      # DHCP — serves IPv4 and IPv6 for ADU network
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
        lan = {
          _type = "dhcp";
          interface = "lan";
          start = 100;
          limit = 150;
          leasetime = "12h";
          dhcpv4 = "server";
          dhcpv6 = "server";
          ra = "server";
          ra_flags = [ "managed-config" "other-config" ];
          ignore = false;
        };
      };

      # LEDs disabled
      system = {
        led_status = {
          _type = "led";
          _anonymous = true;
          name = "status-off";
          sysfs = "white:status";
          trigger = "none";
          default = 0;
        };
        led_phy0 = {
          _type = "led";
          _anonymous = true;
          name = "phy0-off";
          sysfs = "mt76-phy0";
          trigger = "none";
          default = 0;
        };
        led_phy1 = {
          _type = "led";
          _anonymous = true;
          name = "phy1-off";
          sysfs = "mt76-phy1";
          trigger = "none";
          default = 0;
        };
      };
    };
  };
}
