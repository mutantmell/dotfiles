{
  disk ? "/dev/sda",
  root-on-tmpfs ? true,
  tmpfs-size ? "2G",
}: {
  disko.devices = {
    disk.main = {
      device = disk;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
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
    zpool = {
      zroot = {
        type = "zpool";
        rootFsOptions = {
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
        } // (if root-on-tmpfs then {} else {
          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            postCreateHook = "zfs snapshot zroot/local/root@blank";
            options."com.sun:auto-snapshot" = "false";
          };
        });
      };
    };
  } // (if !root-on-tmpfs then {} else {    
    nodev."/" = {
      fsType = "tmpfs";
      mountOptions = [
        "size=${tmpfs-size}"
        "defaults"
        "mode=755"
      ];
    };
  });
}
