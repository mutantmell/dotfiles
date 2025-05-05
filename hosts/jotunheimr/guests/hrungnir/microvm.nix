{ pkgs, config, lib, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  } {
    source = "/data/guests/hrungnir/static";
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  }];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [{
    autoCreate = true;
    mountPoint = "/persist";
    image = "/data/guests/hrungnir/images/persist.img";
    size = 10 * 1024;
  }];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 521;

  microvm.vcpu = 1;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-100-hrungnir";
    mac = "5E:A5:4D:A3:A0:1A";
  }];
}
