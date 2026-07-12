# Linksys E8450 (UBI) — mesh AP with IoT VLAN
{owrtData, ...}: let
  inherit (owrtData) mkAddresses mkGateway;
in {
  imports = [./modules/hardware/linksys-e8450-mesh.nix];

  openwrt = {
    hostname = "derfflinger";
    device.hostId = 21;
    mesh = {
      heBssColor = 25;
      legacyRates = true;
    };
    packages.extra = ["usteer"];
    uci.extraConfig = {
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
          device = "radio0";
          mode = "ap";
          encryption = "sae-mixed";
          network = "iot";
          ssid = {_secret = "wifi.iot.ssid";};
          key = {_secret = "wifi.iot.key";};
        };
      };
    };
  };
}
