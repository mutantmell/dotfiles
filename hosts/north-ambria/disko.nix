{lib, ...}:
import ../../profiles/disko/btrfs.nix {
  disk = "/dev/disk/by-id/nvme-WD_BLACK_SN850X_1000GB_24253Y803154";
  inherit lib;
}
