# Linksys E8450 (UBI) — mesh AP
{
  imports = [./modules/profiles/mesh-ap.nix];

  openwrt = {
    hostname = "lusitania";
    image = {
      profile = "linksys_e8450-ubi";
      target = "mediatek";
      subtarget = "mt7622";
    };
    device.hostId = 24;
    mesh = {
      heBssColor = 58;
      legacyRates = false;
    };
    packages.extra = ["usteer"];
  };
}
