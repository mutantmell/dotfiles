{ config, pkgs, lib, ... }:

{
  home.username = "mjollnir";

  programs.git = {
    userName = "mutantmell";
    userEmail = "malaguy@gmail.com";
  };
}
