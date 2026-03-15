{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  h = net.hosts;
  mgmt = net.networks.management;
  inherit (net.networks) trusted;
in {
  environment.systemPackages = with pkgs; [
    smartmontools
    jdupes
    ncdu
    rclone
    sshfs
  ];

  # Source-restricted firewall rules for NAS services
  networking.firewall.extraInputRules = ''
    # NFS from VM hosts and vHOME
    ip saddr { ${h.calvard.ipv4}, ${h.erebonia.ipv4}, ${trusted.subnet4} } tcp dport 2049 accept
    ip6 saddr { ${h.calvard.ipv6}, ${h.erebonia.ipv6}, ${trusted.subnet6} } tcp dport 2049 accept
    # SMB from vHOME only
    ip saddr ${trusted.subnet4} tcp dport { 139, 445 } accept
    ip6 saddr ${trusted.subnet6} tcp dport { 139, 445 } accept
    # WSDD from vHOME only
    ip saddr ${trusted.subnet4} tcp dport 5357 accept
    ip saddr ${trusted.subnet4} udp dport 3702 accept
    ip6 saddr ${trusted.subnet6} tcp dport 5357 accept
    ip6 saddr ${trusted.subnet6} udp dport 3702 accept
  '';

  fileSystems = let
    media = {
      device = "/data/media";
      options = ["bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service"];
    };
    data = {
      device = "/data/data";
      options = ["bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service"];
    };
    backup = {
      device = "/data/backup";
      options = ["bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service"];
    };
  in {
    "/export/rw/media" = media;
    "/export/ro/media" = media;
    "/export/rw/data" = data;
    "/export/ro/data" = data;
    "/export/rw/backup" = backup;
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /data/media ${trusted.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${trusted.subnet6}(rw,sync,no_subtree_check,no_root_squash) ${mgmt.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${mgmt.subnet6}(rw,sync,no_subtree_check,no_root_squash)
      /data/data ${trusted.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${trusted.subnet6}(rw,sync,no_subtree_check,no_root_squash) ${mgmt.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${mgmt.subnet6}(rw,sync,no_subtree_check,no_root_squash)

      /export/ro/media ${mgmt.subnet4}(ro) ${mgmt.subnet6}(ro) ${trusted.subnet4}(ro) ${trusted.subnet6}(ro)
      /export/rw/media ${mgmt.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${mgmt.subnet6}(rw,sync,no_subtree_check,no_root_squash) ${trusted.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${trusted.subnet6}(rw,sync,no_subtree_check,no_root_squash)

      /export/ro/data ${mgmt.subnet4}(ro) ${mgmt.subnet6}(ro) ${trusted.subnet4}(ro) ${trusted.subnet6}(ro)
      /export/rw/data ${mgmt.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${mgmt.subnet6}(rw,sync,no_subtree_check,no_root_squash) ${trusted.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${trusted.subnet6}(rw,sync,no_subtree_check,no_root_squash)

      /export/rw/backup ${mgmt.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${mgmt.subnet6}(rw,sync,no_subtree_check,no_root_squash) ${trusted.subnet4}(rw,sync,no_subtree_check,no_root_squash) ${trusted.subnet6}(rw,sync,no_subtree_check,no_root_squash)
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
      "server string" = "REMIFERIA";
      "netbios name" = "REMIFERIA";
      "netbios aliases" = "JOTUNHEIMR"; # Backward-compat alias during migration
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
        path = "/export/rw/backup";
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
