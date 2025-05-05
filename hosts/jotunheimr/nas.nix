{ config, pkgs, lib, ... }:
{
  environment.systemPackages = with pkgs; [
    smartmontools
    jdupes
    ncdu
    rclone
    sshfs
  ];
  
  networking.firewall.allowedTCPPorts = [
    445   # smb
    139   # smb
    2049  # nfs
    5357  # wsdd
  ];
  networking.firewall.allowedUDPPorts = [
    137  # smb
    138  # smb
    3702 # wsdd
  ];

  fileSystems = let
    media = {
      device = "/data/media";
      options = [ "bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service" ];
    };
    data = {
      device = "/data/data";
      options = [ "bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service" ];
    };
    backup = {
      device = "/data/backup";
      options = [ "bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service" ];
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
    #    createMountPoints = true;
    exports = ''
      /data/media 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash)
      /data/data 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash)

      /export/ro/media 10.0.10.0/24(ro) 10.0.20.0/24(ro)
      /export/rw/media 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash)

      /export/ro/data 10.0.10.0/24(ro) 10.0.20.0/24(ro)
      /export/rw/data 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash)

      /export/rw/backup 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash) 10.1.10.0/24(rw,sync,no_subtree_check,no_root_squash) 10.1.20.0/24(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  services.devmon.enable = true;
  services.udisks2.enable = true;
  boot.supportedFilesystems = [ "ntfs" ];

  services.samba-wsdd.enable = true;
  services.samba = {
    enable = true;
    #enableNmbd = false;
    #enableWinbindd = false;
    openFirewall = true;
    settings.global = {
      "invalid users" = [ "root" ];
      "passwd program" = "/run/wrappers/bin/passwd %u";
      security = "user";
      "map to guest" = "Bad User";
      "server string" = "JOTUNHEIMR";
      "netbios name" = "JOTUNHEIMR";
      "load printers" = "no";
      "printcap name" = "/dev/null";
    };
    settings = {
      drive = {
        path = "/data/drive";
        browseable = "yes";
        "guest ok" = "no";
        "read only" = "no";
        #        "valid users" = "mjollnir";
        #        "force user" = "mjollnir";
      };
      media = {
        path = "/data/media";
        browseable = "yes";
        "guest ok" = "no";
        "read only" = "no";
        #        "valid users" = "mjollnir";
        #        "force user" = "mjollnir";
      };
      backup = {
        path = "/export/rw/backup";
        browseable = "yes";
        "guest ok" = "no";
        "read only" = "no";
        #        "valid users" = "mjollnir";
        #        "force user" = "mjollnir";
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
