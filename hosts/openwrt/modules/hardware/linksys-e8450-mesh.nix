# Linksys E8450 (UBI) hardware defaults for mesh access points.
{
  imports = [../profiles/mesh-ap.nix];

  openwrt.image = {
    profile = "linksys_e8450-ubi";
    target = "mediatek";
    subtarget = "mt7622";
  };
}
