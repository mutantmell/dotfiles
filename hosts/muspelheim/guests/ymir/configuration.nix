{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./monit.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  environment.systemPackages = with pkgs; [
    git
  ];

  common.networking = {
    enable = true;
    hostname = "ymir";
    interface = "ens3";
  };
  time.timeZone = "UTC";

  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.common.data.certs.root) ];

  common.openssh.enable = true;

  system.stateVersion = "22.11";

}

