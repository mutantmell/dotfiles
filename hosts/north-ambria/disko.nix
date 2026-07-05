{lib, ...}:
import ../../profiles/disko/btrfs.nix {
  disk = "/dev/nvme0n1";
  inherit lib;
}
