{
  pkgs,
  config,
  ...
}: let
  hostname = "langport";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
    ./sops.nix
    # TODO: re-enable after cloud host is deployed (Step 4 Phase 3)
    # proxy.nix serves external domains (mutantmell.net, auth.mutantmell.net) but
    # step-ca HTTP-01 can't validate public domains on an internal-only host.
    # Needs cloud host with Let's Encrypt for external TLS termination.
    # ./proxy.nix
  ];

  environment.systemPackages = [
    pkgs.home-manager
    pkgs.git
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
    matchConfig.MACAddress = "5E:64:00:29:00:01";
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
  networking.extraHosts = net.mkExtraHosts ["phantasma" "messeldam" "basel" "oracion"];

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
        host = "messeldam";
        proto = "tcp";
        port = 443;
        comment = "OIDC auth to messeldam";
      }
      {
        host = "basel";
        proto = "tcp";
        port = 443;
        comment = "ACME certs from basel";
      }
      {
        host = "oracion";
        proto = "tcp";
        port = [80 443];
        comment = "Backend proxy to oracion";
      }
      {
        host = "tharbad";
        proto = "tcp";
        port = 3100;
        comment = "Loki log push";
      }
      {
        host = "tharbad";
        proto = "tcp";
        port = 8427;
        comment = "metrics push";
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

  fluent-bit-agent.enable = true;
  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
