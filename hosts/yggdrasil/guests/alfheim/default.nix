{ pkgs, config, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./modules/dns.nix
    ./modules/proxy.nix
  ];

  networking.hostName = "alfheim";

  common.openssh.enable = true;
  services.openssh.hostKeys = [{
    path = "/static/etc/ssh/ssh_host_ed25519_key";
    type = "ed25519";
  }];

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:11:AD:01:00:02";
    networkConfig = {
      Address = [ "10.0.11.2/24" "fdc6:55f2:0a5e:b::2/64" ];
      Gateway = "10.0.11.1";
      DNS = [ "127.0.0.1" ];  # Use local DNS (Adguard -> Unbound)
      IPv6AcceptRA = false;
      DHCP = "no";
    };
    routes = [
      { Gateway = "10.0.11.1"; }
      { Gateway = "fdc6:55f2:0a5e:b::1"; }
    ];
  };

  networking.extraHosts = ''
    10.0.11.1 yggdrasil.local
    10.0.20.30 gridr.local
    10.0.100.40 surtr.local
  '';

  time.timeZone = "UTC";
  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/private/AdGuardHome"  # Adguard Home state
    ];
    files = [
      "/etc/machine-id"
    ];
  };

  system.stateVersion = "24.11";
}
