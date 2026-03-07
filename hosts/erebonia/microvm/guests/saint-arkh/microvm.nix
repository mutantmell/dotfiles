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
      source = "/persist/guests/saint-arkh/static";
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
      image = "/persist/guests/saint-arkh/images/persist.img";
      size = 25 * 1024;
    }
    {
      autoCreate = true;
      image = "/persist/guests/saint-arkh/images/store-overlay.img";
      mountPoint = config.microvm.writableStoreOverlay;
      size = 4 * 1024;
    }
  ];
  microvm.writableStoreOverlay = "/nix/.rw-store";
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 4096;
  microvm.vcpu = 4;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-100-s-arkh";
      mac = "5E:64:00:3D:00:01";
    }
  ];
}
