# Disko profile for Incus VMs: GPT + EFI + XFS root.
#
# XFS is chosen over ext4 for resilience: when the disk fills up, XFS returns
# ENOSPC without journal corruption or forced read-only remount. ext4 can
# corrupt its journal on full disk, requiring a tear-down and recreate.
#
# No LUKS — the host disk is already encrypted; encrypting the VM image adds
# overhead with no security benefit.
#
# imageSize is the initial qcow2 size (just large enough for the NixOS closure).
# Incus grows the disk to limits.disk at runtime, and boot.growPartition +
# systemd-growfs expand the partition and filesystem on boot.
{disk ? "/dev/vda", ...}: {
  disko.devices.disk.main = {
    type = "disk";
    device = disk;
    imageSize = "10G";
    content = {
      type = "gpt";
      partitions = {
        esp = {
          name = "ESP";
          size = "256M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = ["fmask=0077" "dmask=0077"];
          };
        };
        root = {
          name = "nixos";
          size = "100%";
          content = {
            type = "filesystem";
            format = "xfs";
            mountpoint = "/";
            mountOptions = ["defaults" "noatime"];
          };
        };
      };
    };
  };

  disko.imageBuilder.imageFormat = "qcow2";
}
