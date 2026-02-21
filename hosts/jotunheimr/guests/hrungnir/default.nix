{ pkgs, config, ... }:

let
  hostname = "hrungnir";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./attic.nix
    ./git.nix
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
    matchConfig.MACAddress = "5E:A5:4D:A3:A0:1A";
    networkConfig = {
      Address = [ host.cidr4 host.cidr6 ];
      Gateway = zone.gateway4;
      DNS = [ zone.gateway4 zone.gateway6 ];
      IPv6AcceptRA = false;
      DHCP = "no";
      MulticastDNS = true;
      LLMNR = true;
    };
    routes = [
      { Gateway = zone.gateway4; }
      { Gateway = zone.gateway6; }
    ];
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
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter (
    net.mkDualEgressRules zone [
      { gateway = true; proto = "udp"; port = 53; }
      { gateway = true; proto = "tcp"; port = 53; }
    ] ++ [
      "ip daddr 224.0.0.251 udp dport 5353 accept"    # mDNS IPv4
      "ip6 daddr ff02::fb udp dport 5353 accept"       # mDNS IPv6
      "ip daddr 224.0.0.252 udp dport 5355 accept"     # LLMNR IPv4
      "ip6 daddr ff02::1:3 udp dport 5355 accept"      # LLMNR IPv6
    ]
  );

  system.stateVersion = "23.11";
}
