{
  pkgs,
  config,
  lib,
  ...
}: {
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vsock.cid = 8;

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    {
      source = "/persist/guests/tharbad/static";
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
      image = "/persist/guests/tharbad/images/persist.img";
      size = 30 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 4096;

  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-11-tharbad";
      mac = "5E:A2:E4:CB:05:DA";
    }
  ];
}
