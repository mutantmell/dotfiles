{ config, pkgs, ... }:

let
  dataDir = "/mnt/nas";
  credentials_file = "/nas/credentials";
in {
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "njord";

  environment.systemPackages = with pkgs; [
    git
  ];

  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    MaxFileSec=7day
  '';

  time.timeZone = "UTC";

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;

  users.mutableUsers = false;
  users.users = let
    keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPoCCiFtZ//7igTH9ChEXLkUsA35xzX33ZkhPY0KOohO malaguy@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
    ];
  in {
    root.openssh.authorizedKeys.keys = keys;
    git = {
      uid = 1000;
      isNormalUser = true;
      createHome = true;
      home = "/var/lib/git";
      shell = "${pkgs.git}/bin/git-shell";
      openssh.authorizedKeys.keys = keys;
    };
  };

  fileSystems = {
    "${dataDir}" = {
      device = "/git";
      fsType = "9p";
      options = [ "trans=virtio" "version=9p2000.L" ];
    };
    "/git" = {
      device = dataDir;
      options = [ "bind" ];
    };
  };

  environment.etc = let
    etcdir = "git/setup";
  in {
    "${etcdir}/git-dir-init" = {
      mode = "700";
      text = ''
        #!/usr/bin/env bash

        set -e

        if ! [ "$(id -u)" = 0 ]; then
           echo "Script must be run as root."
           exit 1
        fi

        if [ -f "/etc/${etcdir}/.has-run" ]; then
          echo "Script has already run"
          exit 0
        fi

        sudo -u git mkdir -p ${dataDir}/git
        chown git ${dataDir}/git
        ln -s ${dataDir}/git /git
        chown git /git

        touch /etc/${etcdir}/.has-run
      '';
    };
  };

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  system.stateVersion = "22.11";
}
