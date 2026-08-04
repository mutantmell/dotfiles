{
  config,
  lib,
  openwrtLib,
  ...
}: let
  cfg = config.openwrt;
  secret = name: {_secret = "bt8bridge.${name}";};
in {
  config.openwrt = {
    device.role = "wirelessBridge";
    locale.country = "GB";
    packages.base = [
      "-dnsmasq"
      "-odhcpd-ipv6only"
      "-ppp"
      "-ppp-mod-pppoe"
      "-wpad-basic-mbedtls"
      "kmod-batman-adv"
      "batctl-full"
      "wpad-mesh-openssl"
      "luci-ssl"
      "luci-proto-batman-adv"
      "tcpdump"
    ];
    uci.radiosToEnable = ["radio0" "radio1" "radio2"];
    uci.generatedConfig =
      lib.recursiveUpdate
      (openwrtLib.mkSystemConfig {
        inherit (cfg) hostname;
        inherit (cfg.locale) timezone;
      })
      {
        network = {
          loopback = {
            _type = "interface";
            device = "lo";
            proto = "static";
            ipaddr = "127.0.0.1";
            netmask = "255.0.0.0";
          };
          globals = {
            _type = "globals";
            packet_steering = true;
          };
          bat0 = {
            _type = "interface";
            proto = "batadv";
            routing_algo = "BATMAN_V";
            gw_mode = "off";
            hop_penalty = 30;
            multipath = false;
          };
          wired = {
            _type = "interface";
            proto = "batadv_hardif";
            device = "wan";
            master = "bat0";
            mtu = 1536;
          };
          bat0_wifi = {
            _type = "interface";
            proto = "batadv_hardif";
            master = "bat0";
            mtu = 1536;
          };
          bat0_10 = {
            _type = "device";
            type = "8021q";
            ifname = "bat0";
            vid = 10;
            name = "bat0.10";
          };
          br_mgmt = {
            _type = "device";
            type = "bridge";
            name = "br-mgmt";
            # Keep LAN1 as an untagged management recovery port so the bridge
            # remains reachable with a statically addressed client if BATMAN
            # is unavailable during the initial rollout.
            ports = ["bat0.10" "lan1"];
          };
          mgmt = {
            _type = "interface";
            proto = "static";
            device = "br-mgmt";
            ipaddr = "10.91.10.4";
            netmask = "255.255.255.0";
            gateway = "10.91.10.1";
            dns = ["10.91.10.10"];
          };
          bat0_20 = {
            _type = "device";
            type = "8021q";
            ifname = "bat0";
            vid = 20;
            name = "bat0.20";
          };
          br_home = {
            _type = "device";
            type = "bridge";
            name = "br-home";
            ports = ["bat0.20" "lan2" "lan3"];
          };
          home_l2 = {
            _type = "interface";
            proto = "none";
            device = "br-home";
          };
          bat0_30 = {
            _type = "device";
            type = "8021q";
            ifname = "bat0";
            vid = 30;
            name = "bat0.30";
          };
          br_guest = {
            _type = "device";
            type = "bridge";
            name = "br-guest";
            bridge_empty = true;
            ports = ["bat0.30"];
          };
          guest_l2 = {
            _type = "interface";
            proto = "none";
            device = "br-guest";
          };
        };
        wireless = {
          radio0 = {
            _type = "wifi-device";
            type = "mac80211";
            path = "soc/11300000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0";
            radio = 0;
            band = "2g";
            channel = 1;
            htmode = "EHT20";
            country = "GB";
            disabled = true;
          };
          radio1 = {
            _type = "wifi-device";
            type = "mac80211";
            path = "soc/11300000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0";
            radio = 1;
            band = "5g";
            channel = 36;
            htmode = "EHT80";
            country = "GB";
            disabled = true;
          };
          radio2 = {
            _type = "wifi-device";
            type = "mac80211";
            path = "soc/11300000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0";
            radio = 2;
            band = "6g";
            channel = 85;
            htmode = "EHT80";
            country = "GB";
            disabled = true;
          };
          batmesh = {
            _type = "wifi-iface";
            device = "radio2";
            mode = "mesh";
            network = "bat0_wifi";
            encryption = "sae";
            mesh_id = secret "mesh.id";
            key = secret "mesh.key";
            mesh_fwding = false;
          };
          guest_main = {
            _type = "wifi-iface";
            device = "radio0";
            mode = "ap";
            network = "guest_l2";
            encryption = "sae-mixed";
            ssid = secret "aps.guest-main.id";
            key = secret "aps.guest-main.key";
          };
          guest_secondary = {
            _type = "wifi-iface";
            device = "radio1";
            mode = "ap";
            network = "guest_l2";
            encryption = "sae";
            ssid = secret "aps.guest-secondary.id";
            key = secret "aps.guest-secondary.key";
          };
          game = {
            _type = "wifi-iface";
            device = "radio1";
            mode = "ap";
            network = "guest_l2";
            encryption = "sae-mixed";
            ssid = secret "aps.game.id";
            key = secret "aps.game.key";
          };
        };
        dropbear.main = {
          _type = "dropbear";
          PasswordAuth = false;
          RootPasswordAuth = false;
          Port = 22;
        };
        firewall = {
          defaults = {
            _type = "defaults";
            input = "REJECT";
            output = "ACCEPT";
            forward = "REJECT";
          };
          mgmt = {
            _type = "zone";
            name = "mgmt";
            network = ["mgmt"];
            input = "REJECT";
            output = "ACCEPT";
            forward = "REJECT";
          };
          allow_admin = {
            _type = "rule";
            name = "Allow-management-services";
            src = "mgmt";
            src_ip = ["10.91.10.0/24" "10.97.20.0/24"];
            proto = "tcp";
            dest_port = [22 80 443];
            target = "ACCEPT";
          };
          allow_ping = {
            _type = "rule";
            name = "Allow-management-ping";
            src = "mgmt";
            src_ip = ["10.91.10.0/24" "10.97.20.0/24"];
            proto = "icmp";
            target = "ACCEPT";
          };
        };
      };
  };
}
