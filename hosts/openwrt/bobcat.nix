# Linksys E8450 (UBI) — mesh AP
{ owrtData }:
{
  type = "meshAP";
  hostname = "bobcat";
  profile = "linksys_e8450-ubi";
  target = "mediatek";
  subtarget = "mt7622";
  hostId = 23;
  timezone = owrtData.defaultTimezone;
  country = owrtData.defaultCountry;
  heBssColor = 49;
  legacyRates = false;
  extraPackages = [];
}
