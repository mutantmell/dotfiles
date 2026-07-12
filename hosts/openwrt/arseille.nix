# NETGEAR GS108T v3 — managed switch with VLAN-filtering bridge
{
  imports = [./modules/profiles/switch.nix];

  openwrt = {
    hostname = "arseille";
    image = {
      profile = "netgear_gs108t-v3";
      target = "realtek";
      subtarget = "rtl838x";
    };
    device.hostId = 12;
    switch.vlanId = 10;
    packages.extra = ["luci" "luci-proto-batman-adv"];
  };
}
