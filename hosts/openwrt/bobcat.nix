# Linksys E8450 (UBI) — mesh AP
{
  imports = [./modules/hardware/linksys-e8450-mesh.nix];

  openwrt = {
    hostname = "bobcat";
    device.hostId = 23;
    mesh = {
      heBssColor = 49;
      legacyRates = false;
    };
  };
}
