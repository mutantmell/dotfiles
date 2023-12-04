{ config, pkgs, ... }:

{

  nix = {
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };
  nixpkgs.config.allowUnfree = true;

  imports =
    [
      ./hardware-configuration.nix
      ./sops.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  time.timeZone = "America/Los_Angeles";

  common.networking = {
    enable = true;
    hostname = "skadi";
    interface = "ens3";
  };
  networking.firewall.allowedUDPPorts = [ 5353 ];
  services.avahi.publish.userServices = true;
  services.avahi.publish.workstation = true;
  networking.extraHosts = ''
    10.0.10.1 yggdrasil
    10.0.10.1 yggdrasil.local
    10.0.10.2 alfheim
    10.0.10.2 alfheim.local
    10.0.100.40 surtr.local
    10.0.100.50 bragi.local
    10.0.100.51 njord.local
  '';

  users.users.mjollnir = {
    isNormalUser = true;
    extraGroups = [ "wheel" "systemd-journal" ];
    uid = 1000;
  };
  common.openssh = {
    enable = true;
    users = [ "mjollnir" ];
    keys = [ "home" ];
    allowPassword = true;
  };

  fileSystems."/mnt/drive" = let
    user = config.users.extraUsers.mjollnir;
    group = config.users.groups.users;
  in {
    device = "//jotunheimr.local/drive";
    fsType = "cifs";
    options = let
      mount_opts = "uid=${toString user.uid},forceuid,gid=${toString group.gid},forcegid";
      automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";
    in ["${mount_opts},${automount_opts},credentials=${config.sops.secrets.smb-credentials.path}"];
  };

  environment.systemPackages = with pkgs; [
    wget
    vim
    git
  ];

  services.openssh.enable = true;
  services.openssh.settings.X11Forwarding = true;

  system.stateVersion = "23.05";

}
