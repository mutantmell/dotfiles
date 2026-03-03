# Linksys E8450 (UBI) — temporary router while thebeyond is down
# Replaces thebeyond as network gateway with limited feature set.
# When thebeyond returns, switch back to bobcat.nix (mesh AP config).
{ owrtData }:
{
  type = "router";
  hostname = "bobcat";
  profile = "linksys_e8450-ubi";
  target = "mediatek";
  subtarget = "mt7622";
  timezone = owrtData.defaultTimezone;
  country = owrtData.defaultCountry;
  encryption = owrtData.defaultEncryption;
  trunkPorts = owrtData.defaultRouterTrunkPorts;
  extraPackages = [];
}
