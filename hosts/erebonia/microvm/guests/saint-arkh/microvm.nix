{lib, ...}: {
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vsock.cid = 3;

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    {
      source = "/persist/guests/saint-arkh/static";
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
      image = "/persist/guests/saint-arkh/images/persist.img";
      size = 25 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 4096;
  microvm.vcpu = 4;
  microvm.interfaces = [
    {
      type = "macvtap";
      id = "vm-50-s-arkh";
      mac = "5E:64:00:3D:00:01";
      macvtap.link = "uplink.50";
      macvtap.mode = "bridge";
    }
  ];
}
