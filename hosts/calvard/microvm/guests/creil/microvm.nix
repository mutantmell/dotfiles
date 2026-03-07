{
  config,
  lib,
  ...
}: {
  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "9p";
    }
    {
      source = "/persist/guests/creil/static";
      mountPoint = "/static";
      tag = "static";
      proto = "virtiofs";
    }
  ];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [
    {
      autoCreate = true;
      mountPoint = "/persist";
      image = "/persist/guests/creil/images/persist.img";
      size = 25 * 1024;
    }
    {
      autoCreate = true;
      image = "/persist/guests/creil/images/store-overlay.img";
      mountPoint = config.microvm.writableStoreOverlay;
      size = 4 * 1024;
    }
  ];
  microvm.writableStoreOverlay = "/nix/.rw-store";
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 2049; # Not exactly 2048 — QEMU hangs at exactly 2GB
  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-100-creil";
      mac = "5E:64:00:35:00:01";
    }
  ];
}
