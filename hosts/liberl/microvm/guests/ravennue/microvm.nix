{lib, ...}: {
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vsock.cid = 6;

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    {
      source = "/persist/guests/ravennue/static";
      mountPoint = "/static";
      tag = "static";
      proto = "virtiofs";
    }
    {
      # ZFS media pool — virtiofs passthrough for local hardlink support
      source = "/data/media";
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
      image = "/persist/guests/ravennue/images/persist.img";
      size = 10 * 1024; # 10GB for arr databases
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 8192; # 8GB — Radarr is memory-hungry
  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-21-ravennue";
      mac = "5E:15:00:2C:00:01";
    }
  ];
}
