{
  pkgs,
  config,
  ...
}: let
  hostname = "saint-arkh";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
  ereboniaHost = (net.forHost "erebonia").host;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
    ./sops.nix
    ./modules/woodpecker.nix
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
    matchConfig.MACAddress = "5E:64:00:3D:00:01";
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
      {
        Destination = "fdc6:55f2:0a5e::/48";
        Gateway = zone.gateway6;
      }
    ];
  };

  networking.extraHosts = net.mkExtraHosts ["basel" "creil" "tharbad"];

  time.timeZone = "UTC";
  common.internal-pki.enable = true;

  # Port 80: ACME HTTP-01 challenge
  # Port 443: Woodpecker UI/API and Forgejo webhook endpoint
  # Port 9000: Woodpecker agent gRPC, scoped below to erebonia's k3s host.
  networking.firewall.allowedTCPPorts = [80 443];
  networking.firewall.extraInputRules = ''
    ip saddr ${ereboniaHost.ipv4} tcp dport 9000 accept
    ip6 saddr ${ereboniaHost.ipv6} tcp dport 9000 accept
  '';

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
      "/var/lib/private/woodpecker-server"
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
        any = true;
        proto = "tcp";
        port = [80 443];
        comment = "HTTP/HTTPS for container image pulls, git fetch";
      }
      {
        gateway = true;
        proto = "udp";
        port = 123;
        comment = "NTP";
      }
      {
        host = "creil";
        proto = "tcp";
        port = 443;
        comment = "Forgejo on creil";
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
    ]
  );

  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
