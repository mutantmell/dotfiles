{ config, pkgs, lib, ... }:

{
  nix = {
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  imports = [
    ./microvm.nix
    ./sops.nix
  ];
  time.timeZone = "America/Los_Angeles";

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  networking.hostName = "skadi";
  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    matchConfig.MACAddress = "5E:A4:B9:D2:F8:03";
    networkConfig = {
      Address = [ "10.0.20.40/24" ];
      Gateway = "10.0.20.1";
      DNS = [ "10.0.20.1" ];
      IPv6AcceptRA = true;
      DHCP = "no";
    };
  };

  services.avahi = {
    enable = true;
    nssmdns4 = false;
    publish = {
      enable = true;
      addresses = true;
      userServices = true;
      workstation = true;
    };
  };
  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  users.users.mjollnir = {
    isNormalUser = true;
    extraGroups = [ "wheel" "systemd-journal" ];
    uid = 1000;
  };
  common.openssh = {
    enable = true;
    users = [ "mjollnir" "root" ];
    keys = [ "home" ];
    allowPassword = true;
  };
  services.openssh.hostKeys = [{
    path = "/static/etc/ssh/ssh_host_ed25519_key";
    type = "ed25519";
  }];

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

  environment.systemPackages = [ pkgs.git ];
  environment.noXlibs = false;

  services.openssh.enable = true;
  services.openssh.settings.X11Forwarding = true;

  system.stateVersion = "23.11";

}
