{ pkgs, config, lib, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
    #proto = "9p";
  } {
    source = "/data/guests/gridr/static";
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  } {
    source = "/data/guests/gridr/static";
    mountPoint = "/persist";
    tag = "persist";
    proto = "virtiofs";
  }];
  fileSystems."/static".neededForBoot = lib.mkForce true;
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 1024;
  microvm.balloonMem = 1024;

  microvm.vcpu = 2;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-100-gridr";
    mac = "5E:6D:F8:D1:E8:AA";
  }];
}
