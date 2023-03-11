{ config, pkgs, ... }:

{

  nix = {
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
   };

  imports =
    [
      ./hardware-configuration.nix
      ./sops.nix

      #./wireguard.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  time.timeZone = "America/Los_Angeles";

  networking.hostName = "skadi";

  users.users.mjollnir = {
    isNormalUser = true;
    extraGroups = [ "wheel" "systemd-journal" ];
    uid = 1000;

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
    ];
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
