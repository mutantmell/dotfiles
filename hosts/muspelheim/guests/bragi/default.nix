{ config, pkgs, ...}:

{
  imports = [
    ./microvm.nix
    ./modules/jellyfin.nix
  ];

  networking.hostName = "bragi";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  nixpkgs.overlays = [(final: prev: {
    vaapiIntel = prev.vaapiIntel.override { enableHybridCodec = true; };
  })];

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:45:07:58:F0:82";
    networkConfig = {
      Address = [ "10.0.100.50/24" ];
      Gateway = "10.0.100.1";
      DNS = [ "10.0.100.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };

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
    "ip daddr 10.0.100.1 udp dport 53 accept"   # DNS to gateway
    "ip daddr 10.0.100.1 tcp dport 53 accept"
    "ip daddr 10.0.20.30 tcp dport 443 accept"   # ACME certs to gridr
    "ip daddr 224.0.0.251 udp dport 5353 accept"  # mDNS multicast
    "ip daddr 239.255.255.250 udp dport 1900 accept"  # SSDP/UPnP multicast
  ];

  system.stateVersion = "23.11";
}
