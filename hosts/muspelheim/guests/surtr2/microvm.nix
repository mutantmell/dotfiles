{ config, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  } {
    source = "/persist/guests/surtr";
    mountPoint = "/";
    image = "surtr2-root.img";
    size = 6 * 1024;
  } ];
  microvm.volumes = [{
    image = "nix-store-overlay.img";
    mountPoint = config.microvm.writableStoreOverlay;
    size = 4096;
  }];
  microvm.writableStoreOverlay = "/nix/.rw-store";
  microvm.mem = 1024;
  microvm.balloonMem = 1024;
  microvm.vcpu = 1;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-100-surtr2";
    mac = config.systemd.network.networks."20-tap".matchConfig.MACAddress;
  }];
}
