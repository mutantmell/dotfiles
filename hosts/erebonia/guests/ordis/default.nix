{ pkgs, config, ... }:

let
  hostname = "ordis";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
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

  networking.hostName = hostname;
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
      Address = [ host.cidr4 host.cidr6 ];
      Gateway = zone.gateway4;
      DNS = [ zone.gateway4 zone.gateway6 ];
      IPv6AcceptRA = false;
      DHCP = "no";
    };
    routes = [
      { Gateway = zone.gateway4; }
      { Gateway = zone.gateway6; }
    ];
  };
  networking.extraHosts = net.mkExtraHosts [ "plantasma" "roer" "legram" "heimdallr" ];

  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  # Egress filtering — default-drop with explicit allowlist
  networking.nftables.enable = true;
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter (
    net.mkDualEgressRules zone [
      { gateway = true; proto = "udp"; port = 53; }
      { gateway = true; proto = "tcp"; port = 53; }
      { host = "roer"; proto = "tcp"; port = 443; comment = "OIDC auth to roer"; }
      { host = "legram"; proto = "tcp"; port = 443; comment = "ACME certs from legram"; }
      { host = "heimdallr"; proto = "tcp"; port = [ 80 443 ]; comment = "Backend proxy to heimdallr"; }
    ]
  );

  system.stateVersion = "23.11";
}
