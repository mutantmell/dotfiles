{ pkgs, config, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./proxy.nix
  ];

  environment.systemPackages = [
    pkgs.home-manager
    pkgs.git
  ];

  networking.hostName = "surtr";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  common.openssh.enable = true;
  services.openssh.hostKeys = [{
    path = "/static/etc/ssh/ssh_host_ed25519_key";
    type = "ed25519";
  }];

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:41:3F:F4:AB:B4";
    networkConfig = {
      Address = [ "10.0.100.40/24" ];
      Gateway = "10.0.100.1";
      DNS = [ "10.0.100.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };
  networking.extraHosts = ''
    10.0.11.2 alfheim.local
    10.0.20.30 gridr.local
    10.0.100.50 bragi.local
  '';

  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  system.stateVersion = "23.11";
}
