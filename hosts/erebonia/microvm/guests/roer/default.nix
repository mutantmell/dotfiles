{
  pkgs,
  config,
  ...
}: let
  hostname = "roer";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./modules/api.nix
  ];

  networking.hostName = hostname;
  networking.useNetworkd = true;
  networking.useDHCP = false;
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
    # VLAN 11 = 0x0B, host ID 32 = 0x20
    matchConfig.MACAddress = "5E:0B:00:20:00:01";
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

  networking.extraHosts = net.mkExtraHosts ["messeldam" "basel" "erebonia" "tharbad"];

  time.timeZone = "UTC";
  security.pki.certificates = [(builtins.readFile pkgs.mmell.lib.data.pki.root)];

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
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
        comment = "HTTP/HTTPS for package mirrors";
      }
      {
        gateway = true;
        proto = "udp";
        port = 123;
        comment = "NTP";
      }
      {
        host = "messeldam";
        proto = "tcp";
        port = 443;
        comment = "Keycloak OIDC (JWKS fetch, token validation)";
      }
      {
        host = "basel";
        proto = "tcp";
        port = 443;
        comment = "ACME certs from step-ca";
      }
      {
        host = "tharbad";
        proto = "tcp";
        port = 3100;
        comment = "Loki log push";
      }
    ]
  );

  # Allow inbound HTTPS from management zone and DMZ (via forward rules on thebeyond)
  # Port 80 is needed for ACME HTTP-01 challenge from basel during cert bootstrap/renewal.
  networking.firewall.allowedTCPPorts = [80 443];

  promtail-client.enable = true;
  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
