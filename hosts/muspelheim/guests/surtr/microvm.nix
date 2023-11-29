{ config, lib, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  } {
    source = "/persist/guests/surtr";
    mountPoint = "/persist";
    tag = "persist";
    proto = "virtiofs";
  }];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.volumes = [{
    image = "surtr-nix-store-overlay.img";
    mountPoint = config.microvm.writableStoreOverlay;
    size = 4096;
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
