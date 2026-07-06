{lib, ...}: {
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
      source = "/persist/guests/ruan/static";
      mountPoint = "/static";
      tag = "static";
      proto = "virtiofs";
    }
    {
      source = "/data/media";
      mountPoint = "/data/media";
      tag = "media";
      proto = "virtiofs";
    }
    {
      source = "/data/drive";
      mountPoint = "/data/drive";
      tag = "drive";
      proto = "virtiofs";
    }
    {
      source = "/data/backup";
      mountPoint = "/data/backup";
      tag = "backup";
      proto = "virtiofs";
    }
  ];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [
    {
      autoCreate = true;
      mountPoint = "/persist";
      image = "/persist/guests/ruan/images/persist.img";
      size = 5 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 2048;
  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-20-ruan";
      mac = "5E:14:00:33:00:01";
    }
  ];
}
