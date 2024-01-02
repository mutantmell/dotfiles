{ config, pkgs, ...}:

{
  imports = [
    ./microvm.nix
    ./modules/jellyfin.nix
  ];

  networking.hostName = "bragi";

  nixpkgs.overlays = [(final: prev: {
    vaapiIntel = prev.vaapiIntel.override { enableHybridCodec = true; };
  })];
  environment.noXlibs = false;

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:45:07:58:F0:82";
    networkConfig = {
      Address = [ "10.0.100.50/24" ];
      Gateway = "10.0.100.1";
      DNS = [ "10.0.100.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };

  time.timeZone = "UTC";
  common.openssh.enable = true;
  services.openssh.hostKeys = [{
    path = "/static/etc/ssh/ssh_host_ed25519_key";
    type = "ed25519";
  }];
  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  environment.persistence."/persist" = {
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
