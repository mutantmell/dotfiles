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
      source = "/data/guests/ardent/static";
      mountPoint = "/static";
      tag = "static";
      proto = "9p";
    }
  ];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [
    {
      autoCreate = true;
      mountPoint = "/persist";
      image = "/data/guests/ardent/images/persist.img";
      size = 25 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 2049; # exact 2048 causes QEMU hang

  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-100-ardent";
      mac = "5E:A5:4D:A3:A0:1A";
    }
  ];
}
