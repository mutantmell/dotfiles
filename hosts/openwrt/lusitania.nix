# Linksys E8450 (UBI) — mesh AP
{ owrtData }:
{
  type = "meshAP";
  hostname = "lusitania";
  profile = "linksys_e8450-ubi";
  target = "mediatek";
  subtarget = "mt7622";
  hostId = 24;
  timezone = owrtData.defaultTimezone;
  country = owrtData.defaultCountry;
  heBssColor = 58;
  legacyRates = false;
  extraPackages = [ "usteer" ];
}
