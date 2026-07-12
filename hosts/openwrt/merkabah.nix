# Linksys E8450 (UBI) — mesh AP
{
  imports = [./modules/hardware/linksys-e8450-mesh.nix];

  openwrt = {
    hostname = "merkabah";
    device.hostId = 20;
    mesh = {
      heBssColor = 8;
      legacyRates = true;
    };
    packages.extra = ["usteer"];
  };
}
