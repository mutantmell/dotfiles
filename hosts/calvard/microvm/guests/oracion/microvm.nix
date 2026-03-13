{
  config,
  lib,
  ...
}: {
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vsock.cid = 7;

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    {
      source = "/persist/guests/oracion/static";
      mountPoint = "/static";
      tag = "static";
      proto = "virtiofs";
    }
    {
      source = "/mnt/media";
      mountPoint = "/media";
      tag = "media";
      proto = "virtiofs";
    }
  ];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [
    {
      autoCreate = true;
      mountPoint = "/persist";
      image = "/persist/guests/oracion/images/persist.img";
      size = 10 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 3096;

  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-100-oracion";
      mac = "5E:64:00:34:00:01";
    }
  ];
}
