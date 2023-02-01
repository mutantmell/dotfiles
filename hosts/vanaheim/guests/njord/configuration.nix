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

  networking.useDHCP = false;
  networking.interfaces.enp1s0.useDHCP = true;

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

  fileSystems."${dataDir}" = {
    device = "jotunheimr:/data/data/git";
    fsType = "nfs";
  };

  # rec {
  #   device = "//mimisbrunnr/data/git";
  #   fsType = "cifs";
  #   options = let
  #     user = config.users.users.git;
  #     mount_opts = "uid=${toString user.uid},forceuid,file_mode=0770,dir_mode=0770";
  #     automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";
  #   in ["${mount_opts},${automount_opts},credentials=/etc/${credentials_file}"];
  # };

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
      userServices = true;
      workstation = true;
    };
  };

  system.stateVersion = "22.11";
}
