# Linksys E8450 (UBI) — mesh AP
{ owrtData }:
{
  type = "meshAP";
  hostname = "merkabah";
  profile = "linksys_e8450-ubi";
  target = "mediatek";
  subtarget = "mt7622";
  hostId = 20;
  timezone = owrtData.defaultTimezone;
  country = owrtData.defaultCountry;
  heBssColor = 8;
  legacyRates = true;
  extraPackages = [ "usteer" ];
}
