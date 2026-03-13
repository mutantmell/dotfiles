{
  disk ? "/dev/sda",
  tmpfs-size ? "2G",
  ...
}: {
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
              # initrdUnlock = false prevents disko from generating
              # boot.initrd.luks.devices — the host config manages that
              # with preOpenCommands to mount the ESP for the keyfile.
              initrdUnlock = false;
              passwordFile = "/tmp/secret.key";
              settings.allowDiscards = true;
              content = {
                type = "filesystem";
                format = "xfs";
                mountpoint = "/persist";
                mountOptions = [
                  "defaults"
                  "noatime"
                ];
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
