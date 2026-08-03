# ASUS ZenWiFi BT8 bridge.
#
{
  imports = [
    ./modules/hardware/asus-zenwifi-bt8-stock.nix
    ./modules/profiles/wireless-bridge.nix
  ];

  openwrt.hostname = "bt8bridge";
}
