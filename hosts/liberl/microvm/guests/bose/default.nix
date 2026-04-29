{
  pkgs,
  config,
  ...
}: let
  hostname = "bose";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
    ./modules/arr.nix
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
    # VLAN 21 = 0x15, host ID 43 = 0x2B
    matchConfig.MACAddress = "5E:15:00:2B:00:01";
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

  networking.extraHosts = net.mkExtraHosts ["tharbad" "oracion"];

  time.timeZone = "UTC";

  # Sonarr (8989), Radarr (7878), Bazarr (6767) web UIs
  networking.firewall.allowedTCPPorts = [8989 7878 6767];

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
    ];
  };

  # zramSwap as pressure valve for Radarr memory spikes during bulk imports
  zramSwap = {
    enable = true;
    memoryPercent = 50; # ~4GB of 8GB
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
        proto = "udp";
        port = 123;
        comment = "NTP";
      }
      {
        gateway = true;
        proto = "tcp";
        port = [80 443];
        comment = "HTTP/HTTPS for TVDB, TMDB metadata lookups";
      }
      {
        host = "basel";
        proto = "tcp";
        port = 443;
        comment = "SSHPOP cert enrollment";
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
      {
        host = "oracion";
        proto = "tcp";
        port = 8096;
        comment = "Jellyfin API (library scan notifications)";
      }
    ]
  );

  fluent-bit-agent.enable = true;
  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
