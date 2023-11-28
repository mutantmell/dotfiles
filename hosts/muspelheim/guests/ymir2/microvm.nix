{ config, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  }];
  microvm.volumes = [{
    autoCreate = true;
    mountPoint = persist-dir;
    image = "ymir2-persist.img";
    size = 10 * 1024;
  }];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 1024;
  microvm.balloonMem = 1024;
  microvm.vcpu = 1;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-20-ymir2";
    mac = config.systemd.network.networks."20-tap".matchConfig.MACAddress;
  }];
}
