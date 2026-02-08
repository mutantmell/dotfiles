{
  disk ? "/dev/sda",
  tmpfs-size ? "2G",
  ...
}:
{
  disko.devices = {
    disk.main = {
    device = disk;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          name = "boot";
          size = "1M";
          type = "EF02";
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
        zfs = {
          size = "100%";
          content = {
            type = "zfs";
            pool = "zroot";
          };
        };
      };
    };
  };
  zpool.zroot = {
    type = "zpool";
    rootFsOptions = {
      encryption = "on";
      keyformat = "passphrase";
      keylocation = "prompt";
      compression = "zstd";
      mountpoint = "none";
    };
    options.ashift = "12";

    datasets = {
      "local" = {
        type = "zfs_fs";
        options.mountpoint = "none";
      };
      "local/nix" = {
        type = "zfs_fs";
        mountpoint = "/nix";
      };
      "local/persist" = {
        type = "zfs_fs";
        mountpoint = "/persist";
        options."com.sun:auto-snapshot" = "true";
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
