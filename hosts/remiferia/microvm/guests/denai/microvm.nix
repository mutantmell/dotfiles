{lib, ...}: {
  microvm.hypervisor = "qemu";

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "9p";
    }
    {
      source = "/data/guests/denai/static"; # todo: adjust path when vm host changes
      mountPoint = "/static";
      tag = "static";
      proto = "9p";
    }
  ];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [
    {
      autoCreate = true;
      mountPoint = "/";
      image = "/data/guests/denai/images/root.img"; # todo: adjust path when vm host changes
      size = 25 * 1024;
    }
  ];

  microvm.mem = 1024 * 3;

  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-20-denai";
      mac = "5E:A4:B9:D2:F8:03";
    }
  ];
}
