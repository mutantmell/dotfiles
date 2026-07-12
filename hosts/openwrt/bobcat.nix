# Linksys E8450 (UBI) — mesh AP
{
  imports = [./modules/profiles/mesh-ap.nix];

  openwrt = {
    hostname = "bobcat";
    image = {
      profile = "linksys_e8450-ubi";
      target = "mediatek";
      subtarget = "mt7622";
    };
    device.hostId = 23;
    mesh = {
      heBssColor = 49;
      legacyRates = false;
    };
  };
}
