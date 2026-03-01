# OpenWrt device declarations (pure data)
#
# Each device is defined in its own file and returns a plain attrset with a
# `type` field ("meshAP", "switch", "simpleAP", "router") plus device-specific
# parameters including `target`/`subtarget` for the Image Builder. No derivations,
# no pkgs.
#
# Images are built by the Python builder (apps/openwrt/build.py) which downloads
# the upstream OpenWrt Image Builder and runs `make image` with secrets baked in.
#
# Build an image:
#   nix run .#openwrt-build -- <device-name>
#
# Deploy to device:
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
#
# Configure secrets on existing device (without reflashing):
#   nix run .#openwrt-configure-secrets -- <device-ip>
{ lib }:

let
  owrtData = import ../../lib/common/data/openwrt.nix { inherit lib; };
  importDevice = file: import file { inherit owrtData; };
in {
  # Mesh APs — batman-adv mesh, 802.11r/k roaming, wired backhaul
  bobcat      = importDevice ./bobcat.nix;
  lusitania   = importDevice ./lusitania.nix;
  merkabah    = importDevice ./merkabah.nix;
  derfflinger = importDevice ./derfflinger.nix;
  pantagruel  = importDevice ./pantagruel.nix;

  # Temporary router (use while thebeyond is down, then switch back to bobcat)
  bobcat-router = importDevice ./bobcat-router.nix;

  # Managed switch
  arseille    = importDevice ./arseille.nix;

  # Simple AP
  glorious    = importDevice ./glorious.nix;
}
