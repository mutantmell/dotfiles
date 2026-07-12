# Linksys E8450 (UBI) — mesh AP
{
  imports = [./modules/profiles/mesh-ap.nix];

  openwrt = {
    hostname = "pantagruel";
    image = {
      profile = "linksys_e8450-ubi";
      target = "mediatek";
      subtarget = "mt7622";
    };
    device.hostId = 22;
    mesh = {
      heBssColor = 8;
      legacyRates = false;
    };
    packages.extra = ["usteer"];
  };
}
