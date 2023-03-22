{ config, pkgs, lib, ... }:
{
  # services.krb5 = {
  #   enable = true;
  #   realms."JOTUNHEIMR.LOCAL" = {
  #     admin_server = "jotunheimr.local";
  #     kdc = "jotunheimr.local";
  #   };
  #   domain_realm."jotunheimr.local" = "JOTUNHEIMR.LOCAL";
  #   libdefaults.default_realm = "JOTUNHEIMR.LOCAL";
  # };
  # services.kerberos_server = {
  #   enable = true;
  #   realms."JOTUNHEIMR.LOCAL".acl = [
  #     { principal = "*/admin"; access = "all"; }
  #     { principal = "admin"; access = "all"; }
  #   ];
  # };

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
    #88    # kerberos
    #749   # kerberos admin
  ];
  networking.firewall.allowedUDPPorts = [
    137  # smb
    138  # smb
    3702 # wsdd
  ];

  fileSystems."/srv/media" = {
    device = "/data/media";
    options = [ "bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service" ];
  };
  fileSystems."/srv/data" = {
    device = "/data/data";
    options = [ "bind" "defaults" "nofail" "x-systemd.requires=zfs-mount.service" ];
  };

  services.nfs.server = {
    enable = true;
    #    createMountPoints = true;
    exports = ''
      /data/media 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash)
      /data/data 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  services.devmon.enable = true;
  services.udisks2.enable = true;
  boot.supportedFilesystems = [ "ntfs" ];

  services.samba-wsdd.enable = true;
  services.samba = {
    enable = true;
    securityType = "user";
    #enableNmbd = false;
    #enableWinbindd = false;
    openFirewall = true;
    extraConfig = ''
      map to guest = Bad User
      server string = JOTUNHEIMR
      netbios name = JOTUNHEIMR

      load printers = no
      printcap name = /dev/null
    '';

    shares = {
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
    };
  };
}
