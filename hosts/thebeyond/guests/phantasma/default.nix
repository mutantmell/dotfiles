{ pkgs, config, ... }:

let
  hostname = "plantasma";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./modules/dns.nix
    # TODO: Re-enable after roer (Keycloak) + legram (step-ca) are deployed
    # ./modules/proxy.nix
  ];

  networking.hostName = hostname;

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
      Address = [ host.cidr4 host.cidr4Legacy host.cidr6 ];
      Gateway = zone.gateway4;
      DNS = [ "127.0.0.1" ];  # Use local DNS (Adguard -> Unbound)
      IPv6AcceptRA = false;
      DHCP = "no";
    };
    routes = [
      { Gateway = zone.gateway4; }
      { Gateway = zone.gateway6; }
    ];
  };

  networking.extraHosts = ''
    ${zone.gateway4} thebeyond.internal.mutantmell.net thebeyond.internal
    ${zone.gateway4Legacy} thebeyond.internal.mutantmell.net thebeyond.internal
    ${zone.gateway6} thebeyond.internal.mutantmell.net thebeyond.internal
    ${zone.gateway4} yggdrasil.internal
    ${zone.gateway4Legacy} yggdrasil.internal
  '' + net.mkExtraHosts [ "roer" "legram" "ordis" ];

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
