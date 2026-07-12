# OpenWrt device modules. Each file is evaluated with lib.mk-openwrt and
# composes explicit OpenWrt profile modules plus device-local options.
{
  bobcat = ./bobcat.nix;
  lusitania = ./lusitania.nix;
  merkabah = ./merkabah.nix;
  derfflinger = ./derfflinger.nix;
  pantagruel = ./pantagruel.nix;

  arseille = ./arseille.nix;
  glorious = ./glorious.nix;
}
