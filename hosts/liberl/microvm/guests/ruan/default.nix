{
  pkgs,
  config,
  ...
}: let
  hostname = "ruan";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
  inherit (net.networks) trusted;
  inherit (pkgs.mmell.lib.data.users) media;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
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
    # VLAN 20 = 0x14, host ID 51 = 0x33
    matchConfig.MACAddress = "5E:14:00:33:00:01";
    networkConfig = {
      Address = [host.cidr4 host.cidr6];
      Gateway = zone.gateway4;
      DNS = [zone.gateway4 zone.gateway6];
      IPv6AcceptRA = true;
      IPv6PrivacyExtensions = "yes";
      DHCP = "no";
      MulticastDNS = true;
      LLMNR = true;
    };
    routes = [
      {Gateway = zone.gateway4;}
      {
        Destination = "fdc6:55f2:0a5e::/48";
        Gateway = zone.gateway6;
      }
    ];
  };

  networking.extraHosts = net.mkExtraHosts ["basel"];

  time.timeZone = "UTC";

  users.groups = {
    media.gid = media.gid;
    smb = {};
  };
  users.users = {
    media = {
      inherit (media) uid;
      group = "media";
      isSystemUser = true;
    };
    mutantmell = {
      isNormalUser = true;
      description = "guest-local SMB login";
      group = "smb";
      extraGroups = ["media"];
      createHome = false;
    };
  };

  environment.systemPackages = [
    pkgs.samba
    (pkgs.writeShellScriptBin "smb-set-password" ''
      set -euo pipefail
      user="''${1:-mutantmell}"
      exec ${pkgs.samba}/bin/smbpasswd -a "$user"
    '')
  ];

  networking.firewall.extraInputRules = ''
    # SMB from vHOME
    ip saddr ${trusted.subnet4} tcp dport { 139, 445 } accept
    ip6 saddr ${trusted.subnet6} tcp dport { 139, 445 } accept
    # WSDD from vHOME
    ip saddr ${trusted.subnet4} tcp dport 5357 accept
    ip saddr ${trusted.subnet4} udp dport 3702 accept
    ip6 saddr ${trusted.subnet6} tcp dport 5357 accept
    ip6 saddr ${trusted.subnet6} udp dport 3702 accept
  '';

  services.samba-wsdd.enable = true;
  services.samba = {
    enable = true;
    openFirewall = false;
    settings.global = {
      "invalid users" = ["root"];
      "passwd program" = "/run/wrappers/bin/passwd %u";
      security = "user";
      "map to guest" = "Bad User";
      "server string" = "LIBERL";
      "netbios name" = "LIBERL";
      "load printers" = "no";
      "printcap name" = "/dev/null";
    };
    settings = {
      drive = {
        path = "/data/drive";
        browseable = "yes";
        "guest ok" = "no";
        "read only" = "no";
        "valid users" = ["mutantmell"];
        "force user" = "media";
        "force group" = "media";
        "create mask" = "0664";
        "directory mask" = "2775";
      };
      media = {
        path = "/data/media";
        browseable = "yes";
        "guest ok" = "no";
        "read only" = "no";
        "valid users" = ["mutantmell"];
        "force user" = "media";
        "force group" = "media";
        "create mask" = "0664";
        "directory mask" = "2775";
        # Required for MISTer (Linux CIFS client) to follow Unix symlinks -
        # used for mister/games/<Core> -> library/software/console/<platform>/
        "mfs symlinks" = "yes";
      };
      backup = {
        path = "/data/backup";
        browseable = "yes";
        "guest ok" = "no";
        "read only" = "no";
        "valid users" = ["mutantmell"];
        "force user" = "media";
        "force group" = "media";
        "create mask" = "0664";
        "directory mask" = "2775";
      };
    };
  };

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/samba"
      "/var/lib/systemd/coredump"
    ];
  };

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
        host = "basel";
        proto = "tcp";
        port = 443;
        comment = "SSHPOP cert enrollment";
      }
      {
        any = true;
        proto = "udp";
        port = 3702;
        comment = "WSDD discovery replies";
      }
    ]
  );

  system.stateVersion = "25.11";
}
