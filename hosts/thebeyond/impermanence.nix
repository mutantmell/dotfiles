{config, ...}: let
  inherit (config.common.impermanence) persistDir;
in {
  common.impermanence.enable = true;

  # impermanence creates /var/lib/private with 0755 but DynamicUser services require 0700
  # (https://github.com/nix-community/impermanence/issues/254)
  systemd.tmpfiles.rules = ["d /var/lib/private 0700 root root"];

  # Bind mount /nix onto the persistent ext4 partition so the Nix store
  # doesn't land on the 2G tmpfs root (which causes "No space left on device").
  fileSystems."/nix" = {
    device = "${persistDir}/nix";
    fsType = "none";
    options = ["bind"];
    neededForBoot = true;
  };
}
