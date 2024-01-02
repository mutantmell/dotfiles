{ config, lib, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "9p";
  } {
    source = "/persist/guests/bragi/static";
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  } {
    source = "/mnt/media";
    mountPoint = "/media";
    tag = "media";
    proto = "virtiofs";
  }];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [{
    autoCreate = true;
    mountPoint = "/";
    image = "/persist/guests/bragi/images/root.img";
    size = 25 * 1024;
  }];

  microvm.mem = 1024;
  microvm.balloonMem = 1024 * 3;

  microvm.vcpu = 2;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-100-bragi";
    mac = "5E:45:07:58:F0:82";
  }];
}
