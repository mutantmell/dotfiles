{ config, pkgs, ... }:

let
  dataDir = "/mnt/nas";
in {
  imports = [
    ./hardware-configuration.nix
    ./sops.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  common.networking = {
    enable = true;
    hostname = "njord";
    interface = "ens3";
  };
  services.avahi.openFirewall = false;
  
  networking.firewall.interfaces."ens3" = {
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ 5353 ];
  };
  networking.firewall.allowedTCPPorts = [ 8443 ];

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

  users.mutableUsers = false;
  users.users.git = {
    uid = 1000;
    isNormalUser = true;
    createHome = true;
    home = "/var/lib/git";
    shell = "${pkgs.git}/bin/git-shell";
    extraGroups = [ "git" ];
    # openssh.authorizedKeys.keys = [
    #   "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJl4UkXB94b0e/4YrPXIT4J4l73/mCwh724Yr1VFy7dk malaguy@gmail.com"
    #   "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE5AN0gzpx+1bJNZbGfLt4m2kD59WYmyqgIkXmzYbL+Q malaguy@gmail.com"
    #   "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINZ7mLwJ54FpGVAEdqB04CYUi3QH8ZIr3gsDhj220/d+ malaguy@gmail.com"
    # ];
  };
  users.groups.git.gid = 1000;

  common.openssh = {
    enable = true;
    users = [ "git" "root" ];
    keys = [ "deploy" "home" ];
  };
  services.openssh.openFirewall = false;

  fileSystems = {
    "${dataDir}" = {
      device = "/data";
      fsType = "9p";
      options = [ "trans=virtio" "version=9p2000.L" ];
    };
    "/git" = {
      device = "${dataDir}/git";
      options = [ "bind" ];
    };
  };

  services.unifi = {
    enable = true;
    openFirewall = true;
    unifiPackage = pkgs.unifi7;
    maximumJavaHeapSize = 256;
  };

  system.stateVersion = "22.11";
}
