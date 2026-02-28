# OpenWrt device declarations (pure data)
#
# Each device is defined in its own file and returns a plain attrset with a
# `type` field ("meshAP", "switch", "simpleAP") plus device-specific parameters.
# No derivations, no pkgs.
#
# Images are built in flake.nix by mapping mkDeviceImage over these declarations.
#
# SECRETS: Wifi/mesh passwords are NOT included in images (would expose them
# in nix store). Instead, secrets are configured post-deployment via SSH.
# Create hosts/openwrt/secrets/wifi.yaml with: sops hosts/openwrt/secrets/wifi.yaml
#
# Build an image:
#   nix build .#openwrtImages.<device-name>
#
# Deploy to device (includes secrets configuration):
#   nix run .#openwrt-deploy -- <device-name> <device-ip>
#
# Configure secrets on existing device:
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
