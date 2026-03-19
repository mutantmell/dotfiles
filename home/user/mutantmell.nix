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

  programs.ssh.matchBlocks."edith.internal" = {
    user = "mutantmell";
  };
}
