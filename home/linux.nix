{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.git.settings = {
    credential.helper = "${
      pkgs.git.override {withLibsecret = true;}
    }/bin/git-credential-libsecret";
  };
}
