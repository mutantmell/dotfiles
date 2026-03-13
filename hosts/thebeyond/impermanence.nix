{config, ...}: let
  inherit (config.common.impermanence) persistDir;
in {
  common.impermanence.enable = true;

  # Bind mount /nix onto the persistent ext4 partition so the Nix store
  # doesn't land on the 2G tmpfs root (which causes "No space left on device").
  fileSystems."/nix" = {
    device = "${persistDir}/nix";
    fsType = "none";
    options = ["bind"];
    neededForBoot = true;
  };
}
