{
  pkgs,
  config,
  lib,
  ...
}: {
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
      source = "/persist/guests/phantasma/static";
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
      image = "/persist/guests/phantasma/images/persist.img";
      size = 10 * 1024; # 10GB - Blocky query logs + Unbound cache state
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 512; # 512MB - Blocky + Unbound are lightweight
  microvm.vcpu = 1;

  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-10-phantasma";
      mac = "5E:0A:AD:01:00:0A";
    }
  ];
}
