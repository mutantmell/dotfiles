{ pkgs, lib, config, ... }:
let
  mac = "5E:A2:E4:CB:05:DA";
  persist-dir = "/persist";
in {
  imports = [
    #./monit.nix
  ];
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
    inherit mac;
  }];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  common.openssh.enable = true;
  services.openssh.hostKeys = [
    {
      path = "/persist/etc/ssh/ssh_host_ed25519_key"; # todo: "/persist/static/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = mac;
    networkConfig = {
      Address = [ "10.0.20.42/24" ];
      Gateway = "10.0.20.1";
      DNS = [ "10.0.20.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };

  time.timeZone = "UTC";
  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];
  environment.persistence."${persist-dir}" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
    ];
    files = [
      "/etc/machine-id"
    ];
  };

  system.stateVersion = "23.11";
}
