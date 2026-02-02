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
    matchConfig.MACAddress = "5E:10:AD:01:00:02";
    networkConfig = {
      Address = [ "10.0.10.2/24" "10.97.10.2/24" ];
      Gateway = "10.0.10.1";
      DNS = [ "127.0.0.1" ];  # Use local DNS (Adguard -> Unbound)
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };

  networking.extraHosts = ''
    10.0.10.1 yggdrasil.local
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
