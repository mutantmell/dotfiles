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
    2049 # nfs
    #88   # kerberos
    #749  # kerberos admin
  ];

  services.ntp.enable = true;
  services.nfs.server = {
    enable = true;
#    createMountPoints = true;
    exports =''
      /data/media 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash)
      /data/data 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  
  services.samba = {
    enable = false;
    securityType = "user";
    shares = {
      data = {
        path = "/data/share";
        public = false;
        writable = true;
      };
      drive = {
        path = "/some/path";
        public = false;
        writable = true;
      };
      media = {
        path = "/some/path";
        public = false;
        writable = true;
      };
      share = {
        path = "/some/path";
        public = true;
        writable = true;
      };
    };
    extraConfig = ''
      # login to guest if login fails
      map to guest = Bad User
      # fix error with no printers
      load printers = no
      printcap name = /dev/null
      printing = bsd
    '';
  };
}
