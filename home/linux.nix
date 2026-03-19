{
  config,
  pkgs,
  lib,
  ...
}: {
  services.emacs.socketActivation.enable = true;

  programs.git.settings = {
    credential.helper = "${
      pkgs.git.override {withLibsecret = true;}
    }/bin/git-credential-libsecret";
  };
}
