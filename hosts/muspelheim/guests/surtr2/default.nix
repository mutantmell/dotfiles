{ pkgs, config, ... }:
let
  mac = "5E:41:3F:F4:AB:B4";
in {
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  }];
  microvm.volumes = [{
    autoCreate = true;
    mountPoint = "/";
    image = "surtr2-root.img";
    size = 6 * 1024;
  } {
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
    inherit mac;
  }];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = [
    pkgs.home-manager
  ];
  common.openssh.enable = true;
  systemd.network.enable = true;

  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = mac;
    networkConfig = {
      Address = [ "10.0.100.41/24" ];
      Gateway = "10.0.100.1";
      DNS = [ "10.0.100.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };
  system.stateVersion = "23.11";
}