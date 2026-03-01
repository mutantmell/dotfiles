# Linksys E8450 (UBI) — mesh AP with IoT VLAN
{ owrtData }:

let
  inherit (owrtData) mkAddresses mkGateway;
in
{
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
        device = "radio0";
        mode = "ap";
        encryption = "sae-mixed";
        network = "iot";
      };
    };
  };
}
