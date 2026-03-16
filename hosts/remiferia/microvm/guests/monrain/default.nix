{
  pkgs,
  config,
  ...
}: let
  hostname = "monrain";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
    ./modules/git.nix
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
    matchConfig.MACAddress = "5E:A5:4D:A3:A0:20";
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
  services.resolved.enable = true;

  networking.extraHosts = net.mkExtraHosts ["basel" "tharbad"];

  time.timeZone = "UTC";
  security.pki.certificates = [(builtins.readFile pkgs.mmell.lib.data.pki.root)];

  networking.firewall.allowedTCPPorts = [80 443];
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;
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
    files = [
      "/etc/machine-id"
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
        comment = "HTTP/HTTPS for git mirror sync";
      }
      {
        gateway = true;
        proto = "udp";
        port = 123;
        comment = "NTP";
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

  system.stateVersion = "25.11";
}
