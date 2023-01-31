{ config, pkgs, ... }:


let
#  hmFlake = "/home/mjollnir/.config/nixpkgs";

  mkScript = name: script: pkgs.writeScriptBin name ''
    #!${pkgs.runtimeShell}
    ${script}
  '';
in {
  home.stateVersion = "22.05";
  home.username = "mjollnir";
  home.homeDirectory = "/home/mjollnir";
  
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
#    bind
    htop
    tmux
#    weechat
    bitwarden-cli
    git-secret
#    wireguard-tools

    colmena
    age
    step-cli

    # (mkScript "hm-switch" ''
    #   nix flake update '${hmFlake}'
    #   home-manager switch --flake '${hmFlake}#mjollnir'
    # '')
    # (mkScript "nr-switch" ''
    #   sudo nix flake update /etc/nixos/
    #   sudo nixos-rebuild switch
    # '')
    # (mkScript "openwrt-log" ''
    #   while true; do ssh -t root@"$1" screen -R; sleep 10; done
    # '')
  ];

  programs.emacs = {
    enable = true;
    extraPackages = (epkgs: (with epkgs.melpaStablePackages; [
      magit
    ]) ++ (with epkgs.melpaPackages; [
      nix-mode
      dante
    ]));
  };

  services.emacs = {
    enable = true;
    socketActivation.enable = true;
    defaultEditor = true;
  };

  programs.git = {
    enable = true;
    userName = "mutantmell";
    userEmail = "malaguy@gmail.com";
    extraConfig = {
      credential.helper = "${
        pkgs.git.override { withLibsecret = true; }
      }/bin/git-credential-libsecret";
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.bash = {
    enable = true;
  };

  programs.gpg = {
    enable = true;
  };

  services.gpg-agent = {
    enable = true;
  };

  programs.password-store = {
    enable = true;
  };

}
