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
      ./proxy.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  environment.systemPackages = with pkgs; [
    home-manager
    git
  ];

  common.networking = {
    enable = true;
    hostname = "surtr";
    interface = "ens3";
  };
  networking.extraHosts = ''
    10.0.10.2 alfheim.local
  '';

  common.openssh.enable = true;
  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  system.stateVersion = "22.11";

}
