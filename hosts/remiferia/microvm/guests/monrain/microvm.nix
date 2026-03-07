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
      proto = "virtiofs";
    }
    {
      source = "/data/guests/monrain/static";
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
      image = "/data/guests/monrain/images/persist.img";
      size = 25 * 1024;
    }
    {
      autoCreate = true;
      image = "/data/guests/monrain/images/store-overlay.img";
      mountPoint = config.microvm.writableStoreOverlay;
      size = 4 * 1024;
    }
  ];
  microvm.writableStoreOverlay = "/nix/.rw-store";
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 512;
  microvm.vcpu = 1;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-100-monrain";
      mac = "5E:A5:4D:A3:A0:20";
    }
  ];
}
