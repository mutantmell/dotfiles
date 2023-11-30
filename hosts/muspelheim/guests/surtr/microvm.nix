{ config, lib, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    #proto = "virtiofs";
    proto = "9p";
  } {
    source = "/persist/guests/surtr/static";
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  }];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [{
    autoCreate = true;
    mountPoint = "/";
    image = "/persist/guests/surtr/images/root.img";
    size = 25 * 1024;
  } {
    autoCreate = true;
    image = "/persist/guests/surtr/images/store-overlay.img";
    mountPoint = config.microvm.writableStoreOverlay;
    size = 4 * 1024;
  }];
  microvm.writableStoreOverlay = "/nix/.rw-store";

  microvm.mem = 1024;
  microvm.balloonMem = 1024 * 3;

  microvm.vcpu = 2;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-100-surtr";
    mac = "5E:41:3F:F4:AB:B4";
  }];
}
