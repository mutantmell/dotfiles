# Linksys E8450 (UBI) — mesh AP
{
  imports = [./modules/hardware/linksys-e8450-mesh.nix];

  openwrt = {
    hostname = "lusitania";
    device.hostId = 24;
    mesh = {
      heBssColor = 58;
      legacyRates = false;
    };
    packages.extra = ["usteer"];
  };
}
