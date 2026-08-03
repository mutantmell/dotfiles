# ASUS ZenWiFi BT8 using the stock ASUS bootloader/partition layout.
{
  openwrt.image = {
    target = "mediatek";
    subtarget = "filogic";
    profile = "asus_zenwifi-bt8";
  };
}
