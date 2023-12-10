{ config, pkgs, ... }:
{
  services.cgit."git.hrungnir.local" = {
    enable = true;
    scanPath = config.users.users.git.home; #"/var/lib/git";
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

  environment.persistence."/persist" = {
    directories = [
      { directory = "/var/lib/git"; user = "git"; group = "git"; }
    ];
  };
}
