{ pkgs, config, lib, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    #proto = "virtiofs";
    proto = "9p";
  } {
    source = "/persist/guests/ymir/static";
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  }];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [{
    autoCreate = true;
    mountPoint = "/persist";
    image = "/persist/guests/ymir/images/persist.img";
    size = 10 * 1024;
  }];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 1024;
  microvm.balloonMem = 2048;

  microvm.vcpu = 2;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-20-ymir";
    mac = "5E:A2:E4:CB:05:DA";
  }];
}
