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

  # Egress filtering — default-drop with explicit allowlist
  networking.nftables.enable = true;
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter [
    "ip daddr 10.0.100.1 udp dport 53 accept"   # DNS to gateway
    "ip daddr 10.0.100.1 tcp dport 53 accept"
    "ip daddr 10.0.20.30 tcp dport 443 accept"   # OIDC auth + ACME certs to gridr
    "ip daddr 10.0.100.50 tcp dport { 80, 443 } accept"  # Backend proxy to bragi
  ];

  system.stateVersion = "23.11";
}
