{ config, lib, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  } {
    source = "/data/guests/skadi/static"; # todo: adjust path when vm host changes
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  }];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [{
    autoCreate = true;
    mountPoint = "/";
    image = "/data/guests/skadi/images/root.img"; # todo: adjust path when vm host changes
    size = 25 * 1024;
  } {
    autoCreate = true;
    image = "/data/guests/skadi/images/store-overlay.img"; # todo: adjust path when vm host changes
    mountPoint = config.microvm.writableStoreOverlay;
    size = 75 * 1024;
  }];
  microvm.writableStoreOverlay = "/nix/.rw-store";

  microvm.mem = 1024;
  microvm.balloonMem = 1024 * 3;

  microvm.vcpu = 2;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-20-skadi";
    mac = "5E:A4:B9:D2:F8:03";
  }];
}
