# Linksys E8450 (UBI) — mesh AP
{
  imports = [./modules/hardware/linksys-e8450-mesh.nix];

  openwrt = {
    hostname = "pantagruel";
    device.hostId = 22;
    mesh = {
      heBssColor = 8;
      legacyRates = false;
    };
    packages.extra = ["usteer"];
  };
}
