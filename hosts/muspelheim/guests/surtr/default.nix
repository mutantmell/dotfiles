{ pkgs, config, ... }:

let
  hostname = "surtr";
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
      Address = [ host.cidr4 ];
      Gateway = zone.gateway4;
      DNS = [ zone.gateway4 ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };
  networking.extraHosts = ''
    ${net.hosts.alfheim.ipv4} alfheim.local
    ${net.hosts.mimir.ipv4} mimir.local
    ${net.hosts.tyr.ipv4} tyr.local
    ${net.hosts.bragi.ipv4} bragi.local
  '';

  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  # Egress filtering — default-drop with explicit allowlist
  networking.nftables.enable = true;
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter [
    "ip daddr ${zone.gateway4} udp dport 53 accept"   # DNS to gateway
    "ip daddr ${zone.gateway4} tcp dport 53 accept"
    "ip daddr ${net.hosts.mimir.ipv4} tcp dport 443 accept"   # OIDC auth to mimir
    "ip daddr ${net.hosts.tyr.ipv4} tcp dport 443 accept"    # ACME certs from tyr
    "ip daddr ${net.hosts.bragi.ipv4} tcp dport { 80, 443 } accept"  # Backend proxy to bragi
  ];

  system.stateVersion = "23.11";
}
