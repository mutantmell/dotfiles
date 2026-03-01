# NETGEAR GS108T v3 — managed switch with VLAN-filtering bridge
{ owrtData }:
{
  type = "switch";
  hostname = "arseille";
  profile = "netgear_gs108t-v3";
  target = "realtek";
  subtarget = "rtl838x";
  hostId = 12;
  vlanId = 10;
  extraPackages = [ "luci" "luci-proto-batman-adv" ];
}
