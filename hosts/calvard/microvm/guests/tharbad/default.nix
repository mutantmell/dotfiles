{
  pkgs,
  lib,
  config,
  ...
}: let
  hostname = "tharbad";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];

  imports = [
    ./microvm.nix
    ./sops.nix
    ./modules/prometheus.nix
    ./modules/loki.nix
    ./modules/alertmanager.nix
    ./modules/ntfy.nix
    ./modules/perses.nix
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
      IPv6AcceptRA = false;
      DHCP = "no";
    };
    routes = [
      {Gateway = zone.gateway4;}
      {Gateway = zone.gateway6;}
    ];
  };

  networking.extraHosts = net.mkExtraHosts [
    "thebeyond"
    "calvard"
    "erebonia"
    "remiferia"
    "phantasma"
    "basel"
    "messeldam"
    "langport"
    "creil"
    "oracion"
    "ardent"
    "monrain"
    "saint-arkh"
    "trista"
    "edith"
  ];

  time.timeZone = "UTC";
  security.pki.certificates = [(builtins.readFile pkgs.mmell.lib.data.pki.root)];

  # Egress filtering — default-drop with explicit allowlist
  networking.nftables.enable = true;
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter (
    net.mkEgressRules zone (
      [
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
      ]
      # Prometheus scrape targets — node_exporter (port 9100)
      ++ (map (name: {
          host = name;
          proto = "tcp";
          port = 9100;
          comment = "node_exporter scrape";
        }) [
          "thebeyond"
          "calvard"
          "erebonia"
          "phantasma"
          "basel"
          "messeldam"
          "langport"
          "creil"
          "oracion"
          "ardent"
          "monrain"
          "saint-arkh"
          "trista"
          "edith"
        ])
      ++ [
        # Remiferia: non-standard exporter ports
        {
          host = "remiferia";
          proto = "tcp";
          port = [9001 9002 9003];
          comment = "node/zfs/smartctl exporters";
        }
        # ACME certs from basel (for Perses TLS)
        {
          host = "basel";
          proto = "tcp";
          port = 443;
          comment = "ACME certs from basel";
        }
        # Perses OIDC token exchange with Keycloak
        {
          host = "messeldam";
          proto = "tcp";
          port = 443;
          comment = "Keycloak OIDC";
        }
      ]
    )
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
