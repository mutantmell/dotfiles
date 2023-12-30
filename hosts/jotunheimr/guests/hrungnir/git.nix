{ config, pkgs, ... }:
{
  environment.systemPackages = [ pkgs.git ];
  
  services.cgit."hrungnir.local" = {
    enable = true;
    scanPath = config.users.users.git.home;
  };
  
  users.users.git = {
    isSystemUser = true;
    description = "git user";
    home = "/var/lib/git";
    shell = "${pkgs.git}/bin/git-shell";
    group = "git";
    openssh.authorizedKeys.keys = builtins.map (name:
      pkgs.mmell.lib.data.keys.ssh.${name}
    ) [ "deploy" "home" "jotunheimr" "muspelheim" "vanaheim" ];
  };
  users.groups.git = {};

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  environment.persistence."/persist" = {
    directories = [
      { directory = "/var/lib/git"; user = "git"; group = "git"; }
    ];
  };
}
