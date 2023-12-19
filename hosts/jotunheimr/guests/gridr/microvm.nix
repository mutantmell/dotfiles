{ pkgs, config, lib, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  } {
    source = "/data/guests/gridr/static";
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  }];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [{
    autoCreate = true;
    mountPoint = "/persist";
    image = "/data/guests/gridr/images/persist.img";
    size = 100 * 1024;
  }];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 1024;
  microvm.balloonMem = 1024;

  microvm.vcpu = 2;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-20-gridr";
    mac = "5E:6D:F8:D1:E8:AA";
  }];
}
