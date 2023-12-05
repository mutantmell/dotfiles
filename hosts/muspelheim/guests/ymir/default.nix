{ pkgs, lib, config, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  imports = [
    ./monit.nix
    ./microvm.nix
  ];

  common.openssh.enable = true;
  services.openssh.hostKeys = [{
    path = "/static/etc/ssh/ssh_host_ed25519_key";
    type = "ed25519";
  }];

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:A2:E4:CB:05:DA";
    networkConfig = {
      Address = [ "10.0.20.41/24" ];
      Gateway = "10.0.20.1";
      DNS = [ "10.0.20.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };

  services.resolved.enable = true;
  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  time.timeZone = "UTC";
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
