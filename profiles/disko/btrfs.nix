{disk ? "/dev/sda", ...}: {
  disko.devices = {
    disk.main = {
      type = "disk";
      device = disk;
      content = {
        type = "gpt";
        partitions = {
          esp = {
            name = "ESP";
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = ["fmask=0077" "dmask=0077"];
            };
          };
          persist = {
            name = "persist";
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              # initrdUnlock = false prevents disko from generating
              # boot.initrd.luks.devices — the host config manages that
              # via common.btrfs.keyfileUnlock (systemd mount units in initrd).
              initrdUnlock = false;
              passwordFile = "/tmp/secret.key";
              settings.allowDiscards = true;
              content = {
                type = "btrfs";
                extraArgs = ["-f"];
                subvolumes = {
                  "@root" = {
                    mountpoint = "/";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                  "@persist" = {
                    mountpoint = "/persist";
                    mountOptions = ["compress=zstd" "noatime"];
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
