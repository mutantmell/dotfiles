{ config, pkgs, ...}:

{
  #deployment.keys."weechat_passphrase" = {
  #  text = "<REDACTED>";
  #  user = "weechat";
  #  group = "weechat";
  #  permissions = "0400";
  #};
  
  #services.weechat = {
  #  enable = false;
  #};

  programs.screen.screenrc = ''
    multiuser on
    acladd normal_user
  '';

  users.extraUsers.weechat.extraGroups = [ "keys" ];
  
}
