# Linksys E8450 (UBI) — mesh AP
{ owrtData }:
{
  type = "meshAP";
  hostname = "pantagruel";
  profile = "linksys_e8450-ubi";
  hostId = 22;
  heBssColor = 8;
  extraPackages = [ "usteer" ];
}
