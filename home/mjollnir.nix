{ config, pkgs, lib, ... }:

{
  home.username = "mjollnir";
  home.homeDirectory = "/home/mjollnir";

  programs.git = {
    userName = "mutantmell";
    userEmail = "malaguy@gmail.com";
  };
}
