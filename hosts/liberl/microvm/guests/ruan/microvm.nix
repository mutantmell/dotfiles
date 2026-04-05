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
      source = "/persist/guests/ruan/static";
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
      image = "/persist/guests/ruan/images/persist.img";
      size = 25 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 512;
  microvm.vcpu = 1;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-100-ruan";
      mac = "5E:A5:4D:A3:A0:20";
    }
  ];
}
