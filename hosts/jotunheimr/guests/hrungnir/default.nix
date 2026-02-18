{ pkgs, config, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./attic.nix
    ./git.nix
  ];

  networking.hostName = "hrungnir";
  common.openssh.enable = true;
  services.openssh.hostKeys = [{
    path = "/static/etc/ssh/ssh_host_ed25519_key";
    type = "ed25519";
  }];

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:A5:4D:A3:A0:1A";
    networkConfig = {
      Address = [ "10.0.100.31/24" ];
      Gateway = "10.0.100.1";
      DNS = [ "10.0.100.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
      MulticastDNS = true;
      LLMNR = true;
    };
  };
  services.resolved.enable = true;

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

  # Egress filtering — default-drop with explicit allowlist
  networking.nftables.enable = true;
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter [
    "ip daddr 10.0.100.1 udp dport 53 accept"   # DNS to gateway
    "ip daddr 10.0.100.1 tcp dport 53 accept"
    "ip daddr 224.0.0.251 udp dport 5353 accept"  # mDNS multicast
    "ip daddr 224.0.0.252 udp dport 5355 accept"  # LLMNR multicast
  ];

  system.stateVersion = "23.11";
}
