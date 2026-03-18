{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.git.settings.user = {
    name = "mutantmell";
    email = "malaguy@gmail.com";
  };
}
