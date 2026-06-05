{
  pkgs,
  lib,
  config,
  ...
}: let
  hostname = "tharbad";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
  externalHosts = lib.filter (h: h != hostname) net.monitoredHosts;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];

  imports = [
    ./microvm.nix
    ./sops.nix
    ./modules/victorialogs.nix
    ./modules/alertmanager.nix
    ./modules/ntfy.nix
    ./modules/perses.nix
    ./modules/victoriametrics.nix
    ./modules/fluent-bit.nix
    ./modules/ingress.nix
  ];

  networking.hostName = hostname;

  common.openssh = {
    enable = true;
    keys = ["deploy" "edith"];
  };
  services.openssh.hostKeys = [
    {
      path = "/static/etc/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];

  networking.useNetworkd = true;
  networking.useDHCP = false;
  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:A2:E4:CB:05:DA";
    networkConfig = {
      Address = [host.cidr4 host.cidr6];
      Gateway = zone.gateway4;
      DNS = [zone.gateway4 zone.gateway6];
      IPv6AcceptRA = true;
      IPv6PrivacyExtensions = "yes";
      DHCP = "no";
    };
    routes = [
      {Gateway = zone.gateway4;}
      {Gateway = zone.gateway6;}
    ];
  };

  networking.extraHosts = net.mkExtraHosts externalHosts;

  time.timeZone = "UTC";
  common.internal-pki.enable = true;

  # Egress filtering — default-drop with explicit allowlist
  networking.nftables.enable = true;
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter (
    net.mkEgressRules zone [
      {
        gateway = true;
        proto = "udp";
        port = 53;
      }
      {
        gateway = true;
        proto = "tcp";
        port = 53;
      }
      {
        gateway = true;
        proto = "udp";
        port = 123;
        comment = "NTP";
      }
      # ACME certs from basel (for Perses TLS)
      {
        host = "basel";
        proto = "tcp";
        port = 443;
        comment = "ACME certs from basel";
      }
      # Perses OIDC token exchange with Authelia
      {
        host = "messeldam";
        proto = "tcp";
        port = 443;
        comment = "Authelia OIDC";
      }
    ]
  );

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
    ];
  };

  system.stateVersion = "25.11";
}
