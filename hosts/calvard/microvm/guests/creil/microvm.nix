{lib, ...}: {
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vsock.cid = 4;

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    {
      source = "/persist/guests/creil/static";
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
      image = "/persist/guests/creil/images/persist.img";
      size = 25 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 2048;
  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-50-creil";
      mac = "5E:64:00:35:00:01";
    }
  ];
}
