{
  pkgs,
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
      source = "/persist/guests/ymir/static";
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
      image = "/persist/guests/ymir/images/persist.img";
      size = 30 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 2049; # Not exactly 2048 — QEMU hangs at exactly 2GB

  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-11-ymir";
      mac = "5E:0B:11:05:00:01";
    }
  ];
}
