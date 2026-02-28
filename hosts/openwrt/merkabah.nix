# Linksys E8450 (UBI) — mesh AP
{ owrtData }:
{
  type = "meshAP";
  hostname = "merkabah";
  profile = "linksys_e8450-ubi";
  hostId = 20;
  heBssColor = 8;
  legacyRates = true;
  extraPackages = [ "usteer" ];
}
