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
      source = "/persist/guests/roer/static";
      mountPoint = "/static";
      tag = "static";
      proto = "virtiofs";
    }
    # deployd-helper Unix socket — shared from erebonia host
    {
      source = "/run/deployd";
      mountPoint = "/run/deployd-host";
      tag = "deployd-socket";
      proto = "virtiofs";
    }
  ];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [
    {
      autoCreate = true;
      mountPoint = "/persist";
      image = "/persist/guests/roer/images/persist.img";
      size = 2 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 512;
  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-11-roer";
      mac = "5E:0B:00:20:00:01";
    }
  ];
}
