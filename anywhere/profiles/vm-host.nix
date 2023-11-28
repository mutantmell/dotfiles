{
  disk ? "/dev/sda",
  root-on-tmpfs ? true,
  tmpfs-size ? "2G",
  swap-partition ? false,
  swap-size ? "1G",
  swap-encrypted ? true,
  zfs-reservation ? null,
}: {
  disko.devices = {
    disk.main = {
      device = disk;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "1M";
            type = "EF02";
          };
          ESP = {
            size = "512M";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          zfs = {
            content = {
              type = "zfs";
              pool = "zroot";
            };
          } // (if swap-partition then {
            end = "-${swap-size}";
          } else {
            size = "100%";
          });
        } // (if !swap-partition then {} else {
          swap = {
            size = "100%";
            content = {
              type = "swap";
              randomEncryption = swap-encrypted;
            };
          };
        });
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        rootFsOptions = {
          encryption = "on";
          keyformat = "passphrase";
          #keylocation = "file:///tmp/secret.key";
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
        } // (if root-on-tmpfs then {} else {
          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            postCreateHook = "zfs snapshot zroot/local/root@blank";
            options."com.sun:auto-snapshot" = "false";
          };
        }) // (if zfs-reservation == null then {} else {
          "local/reservation" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              refreservation = zfs-reservation;
            };
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
