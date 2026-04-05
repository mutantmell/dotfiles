{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  h = net.hosts;
  inherit (net.networks) trusted;
  inherit (pkgs.mmell.lib.data.users) media;
in {
  environment.systemPackages = with pkgs; [
    smartmontools
    jdupes
    ncdu
    rclone
    sshfs
  ];

  users.groups.media.gid = media.gid;
  users.users.media = {
    inherit (media) uid;
    group = "media";
    isSystemUser = true;
  };

  # Source-restricted firewall rules for NAS services
  networking.firewall.extraInputRules = ''
    # NFS from specific VM hosts only
    ip saddr { ${h.calvard.ipv4}, ${h.erebonia.ipv4} } tcp dport 2049 accept
    ip6 saddr { ${h.calvard.ipv6}, ${h.erebonia.ipv6} } tcp dport 2049 accept
    # SMB from vHOME only
    ip saddr ${trusted.subnet4} tcp dport { 139, 445 } accept
    ip6 saddr ${trusted.subnet6} tcp dport { 139, 445 } accept
    # WSDD from vHOME only
    ip saddr ${trusted.subnet4} tcp dport 5357 accept
    ip saddr ${trusted.subnet4} udp dport 3702 accept
    ip6 saddr ${trusted.subnet6} tcp dport 5357 accept
    ip6 saddr ${trusted.subnet6} udp dport 3702 accept
  '';

  # Bind mounts into the NFS export tree
  # Both RW and RO bind the same root (/data/media); access level is enforced by export options
  fileSystems = let
    media = {
      device = "/data/media";
      options = ["bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service"];
    };
  in {
    "/export/rw/media" = media;
    "/export/ro/media" = media;
  };

  services.nfs.server = {
    enable = true;
    # Per-host exports with UID squashing — no subnet-wide access, no root_squash bypass
    exports = let
      uid = toString media.uid;
      gid = toString media.gid;
    in ''
      /export/rw/media  ${h.erebonia.ipv4}(rw,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid}) ${h.erebonia.ipv6}(rw,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid})
      /export/ro/media  ${h.calvard.ipv4}(ro,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid}) ${h.calvard.ipv6}(ro,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid})
    '';
  };

  services.devmon.enable = true;
  services.udisks2.enable = true;
  boot.supportedFilesystems = ["ntfs"];

  services.samba-wsdd.enable = true;
  services.samba = {
    enable = true;
    openFirewall = false; # Handled by source-restricted extraInputRules above
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
      };
      media = {
        path = "/data/media";
        browseable = "yes";
        "guest ok" = "no";
        "read only" = "no";
      };
      backup = {
        path = "/data/backup";
        browseable = "yes";
        "guest ok" = "no";
        "read only" = "no";
      };
    };
  };

  power.ups = {
    enable = true;
    ups."apc" = {
      driver = "usbhid-ups";
      port = "auto";
      description = "APC UPS";
    };
    users.upsmon = {
      passwordFile = config.sops.secrets."upsmon.password".path;
      upsmon = "primary";
    };
    upsmon.monitor."apc".user = "upsmon";
  };
}
