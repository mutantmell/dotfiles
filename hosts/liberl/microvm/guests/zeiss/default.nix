{
  pkgs,
  config,
  ...
}: let
  hostname = "zeiss";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./attic.nix
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

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:A5:4D:A3:A0:1A";
    networkConfig = {
      Address = [host.cidr4 host.cidr6];
      Gateway = zone.gateway4;
      DNS = [zone.gateway4 zone.gateway6];
      IPv6AcceptRA = true;
      IPv6PrivacyExtensions = "yes";
      DHCP = "no";
      MulticastDNS = false;
      LLMNR = false;
    };
    routes = [
      {Gateway = zone.gateway4;}
      {Gateway = zone.gateway6;}
    ];
  };
  networking.extraHosts = net.mkExtraHosts ["basel"];

  time.timeZone = "UTC";
  security.pki.certificates = [(builtins.readFile pkgs.mmell.lib.data.pki.root)];

  # Shared nginx + ACME for attic vhost
  networking.firewall.allowedTCPPorts = [80 443];
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
  };
  environment.etc."step-ca/data/intermediate_ca.crt" = {
    source = pkgs.mmell.lib.data.pki.intermediate;
    mode = "0444";
  };
  security.acme = {
    defaults = {
      server = "https://basel.internal/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
  };
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      {
        directory = "/var/lib/acme";
        user = "acme";
        group = "acme";
      }
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
    ];
  };

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
        proto = "tcp";
        port = [80 443];
        comment = "GitHub mirror, container image pulls";
      }
      {
        host = "basel";
        proto = "tcp";
        port = 443;
        comment = "ACME certs from basel";
      }
      {
        host = "tharbad";
        proto = "tcp";
        port = 3100;
        comment = "Loki log push";
      }
    ]
  );

  promtail-client.enable = true;
  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
