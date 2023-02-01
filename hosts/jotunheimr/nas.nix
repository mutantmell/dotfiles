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

  networking.firewall.allowedTCPPorts = [
    2049  # nfs
    #88    # kerberos
    #749   # kerberos admin
  ];

  fileSystems = {
    # "export/ro/media" = {
    #   device = "/data/media";
    #   options = [ "bind" "x-systemd.requires=zfs-mount.service" ];
    # };
    "/export/rw/media" = {
      device = "/data/media";
      options = [ "bind" "x-systemd.requires=zfs-mount.service" ];
    };
    # "/export/ro/data" = {
    #   device = "/data/data";
    #   options = [ "bind" "x-systemd.requires=zfs-mount.service" ];
    # };
    "/export/rw/data" = {
      device = "/data/data";
      options = [ "bind" "x-systemd.requires=zfs-mount.service" ];
    };
  };

  services.nfs.server = {
    enable = true;
    #    createMountPoints = true;
    exports = ''
      /export 10.0.10.0/24(rw,fsid=0)
      /export/rw/media 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=11) 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=11)
      /export/rw/data 10.0.10.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=21) 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=21)
    '';
  };

  services.samba = {
    enable = true;
    securityType = "user";
    enableNmbd = false;
    enableWinbindd = false;
    openFirewall = true;
    extraConfig = ''
      map to guest = Bad User

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
