{ config, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  } {
    source = "/persist/guests/ymir";
    mountPoint = "/persist";
    tag = "persist";
    proto = "virtiofs";
  }];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 1024;
  microvm.balloonMem = 1024;

  microvm.vcpu = 2;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-20-ymir";
    mac = config.systemd.network.networks."20-tap".matchConfig.MACAddress;
  }];
}
