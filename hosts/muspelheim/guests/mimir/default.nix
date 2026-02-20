{ pkgs, config, ... }:

let
  hostname = "mimir";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./modules/keycloak.nix
  ];

  networking.hostName = hostname;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:0B:11:03:00:01";
    networkConfig = {
      Address = [ host.cidr4 host.cidr6 ];
      Gateway = zone.gateway4;
      DNS = [ zone.gateway4 ];
      IPv6AcceptRA = false;
      DHCP = "no";
    };
    routes = [
      { Gateway = zone.gateway4; }
      { Gateway = zone.gateway6; }
    ];
  };

  networking.extraHosts = ''
    ${net.hosts.tyr.ipv4} tyr.local
  '';

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

  # Egress filtering — default-drop with explicit allowlist
  networking.nftables.enable = true;
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter [
    "ip daddr ${zone.gateway4} udp dport 53 accept"   # DNS to gateway
    "ip daddr ${zone.gateway4} tcp dport 53 accept"
    "ip daddr ${zone.gateway4} tcp dport { 80, 443 } accept"  # HTTP/HTTPS for package mirrors
    "ip daddr ${zone.gateway4} udp dport 123 accept"  # NTP
    "ip daddr ${net.hosts.tyr.ipv4} tcp dport 443 accept"  # ACME certs from tyr
  ];

  system.stateVersion = "23.11";
}
