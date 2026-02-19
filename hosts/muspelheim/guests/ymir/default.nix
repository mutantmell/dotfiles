{ pkgs, lib, config, ... }:

let
  hostname = "ymir";
  inherit (pkgs.mmell.lib.data.network.forHost hostname) host zone;
in {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  imports = [
    ./monit.nix
    ./microvm.nix
  ];

  networking.hostName = hostname;

  common.openssh.enable = true;
  services.openssh.hostKeys = [{
    path = "/static/etc/ssh/ssh_host_ed25519_key";
    type = "ed25519";
  }];

  networking.useNetworkd = true;
  networking.useDHCP = false;
  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:A2:E4:CB:05:DA";
    networkConfig = {
      Address = [ host.cidr4 ];
      Gateway = zone.gateway4;
      DNS = [ zone.gateway4 ];
      IPv6AcceptRA = true;
      DHCP = "no";
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
