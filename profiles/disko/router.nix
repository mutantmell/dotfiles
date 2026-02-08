{
  disk ? "/dev/sda",
  tmpfs-size ? "2G",
  ...
}:
{
  disko.devices = {
    disk.main = {
    type = "disk";
    device = disk;
    content = {
      type = "gpt";
      partitions = {
        boot = {
          name = "boot";
          size = "1M";
          type = "EF02"; # GRUB boot partition
        };
        esp = {
          name = "ESP";
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        persist = {
          name = "persist";
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            settings = {
              allowDiscards = true;
              # Keyfile path during installation only
              # nixos-anywhere/install-to-disk scripts pass the key here temporarily
              # After installation, the key lives in /boot/secrets/disk.key (see host configuration)
              keyFile = "/tmp/secret.key";
            };
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/persist";
            };
          };
        };
      };
    };
  };
    nodev."/" = {
      fsType = "tmpfs";
      mountOptions = [
        "defaults"
        "size=${tmpfs-size}"
        "mode=755"
      ];
    };
  };
}
