{ config, lib, ... }:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "9p";
  } {
    source = "/persist/guests/legram/static";
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  }];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [{
    autoCreate = true;
    mountPoint = "/persist";
    image = "/persist/guests/legram/images/persist.img";
    size = 10 * 1024;
  } {
    autoCreate = true;
    image = "/persist/guests/legram/images/store-overlay.img";
    mountPoint = config.microvm.writableStoreOverlay;
    size = 4 * 1024;
  }];
  microvm.writableStoreOverlay = "/nix/.rw-store";
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 512;
  microvm.vcpu = 1;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-11-legram";
    mac = "5E:0B:11:04:00:01";
  }];
}
