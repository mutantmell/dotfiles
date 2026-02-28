# OpenWrt device declarations (pure data)
#
# Each device is a plain attrset with a `type` field ("meshAP", "switch",
# "simpleAP") plus device-specific parameters. No derivations, no pkgs.
#
# Images are built in flake.nix by mapping mkDeviceImage over these declarations.
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
{ lib }:

let
  owrtData = import ../../lib/common/data/openwrt.nix { inherit lib; };
  inherit (owrtData) mkAddresses mkGateway;

in {
  # =============================================================================
  # Mesh APs — batman-adv mesh, 802.11r/k roaming, wired backhaul
  # All Linksys E8450 (UBI variant)
  # =============================================================================

  bobcat = {
    type = "meshAP";
    hostname = "bobcat";
    profile = "linksys_e8450-ubi";
    hostId = 23;
    heBssColor = 49;
  };

  lusitania = {
    type = "meshAP";
    hostname = "lusitania";
    profile = "linksys_e8450-ubi";
    hostId = 24;
    heBssColor = 58;
    extraPackages = [ "usteer" ];
  };

  merkabah = {
    type = "meshAP";
    hostname = "merkabah";
    profile = "linksys_e8450-ubi";
    hostId = 20;
    heBssColor = 8;
    legacyRates = true;
    extraPackages = [ "usteer" ];
  };

  derfflinger = {
    type = "meshAP";
    hostname = "derfflinger";
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

  pantagruel = {
    type = "meshAP";
    hostname = "pantagruel";
    profile = "linksys_e8450-ubi";
    hostId = 22;
    heBssColor = 8;
    extraPackages = [ "usteer" ];
  };

  # =============================================================================
  # Managed Switch — VLAN-filtering bridge, no batman-adv
  # NETGEAR GS108T v3
  # =============================================================================

  arseille = {
    type = "switch";
    hostname = "arseille";
    profile = "netgear_gs108t-v3";
    hostId = 12;
    vlanId = 10;
    extraPackages = [ "luci" "luci-proto-batman-adv" ];
  };

  # =============================================================================
  # ADU Router/AP — provides segmented internet access for an ADU
  # Runs firewall + DHCP/DHCPv6/RA, no mesh, no batman-adv
  # TP-Link EAP615-Wall v1 (UNCONFIRMED: verify before deploying)
  # =============================================================================

  glorious = {
    type = "simpleAP";
    hostname = "glorious";
    profile = "tplink_eap615-wall-v1";  # UNCONFIRMED: verify before deploying
    hostId = 20;
    vlanId = 31;
    ssid = "MyAP";
    # Keep dnsmasq (removed by default) — glorious serves DHCP for the ADU network
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
