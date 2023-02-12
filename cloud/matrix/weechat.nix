{ config, pkgs, ...}:

{

  services.weechat = {
    enable = false;
  };

  programs.screen.screenrc = ''
    multiuser on
    acladd normal_user
  '';
}
