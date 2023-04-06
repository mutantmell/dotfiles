{ config, pkgs, sops-nix, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      sops-nix.nixosModules.sops

      ./monit.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  environment.systemPackages = with pkgs; [
    git
  ];

  networking.hostName = "ymir";
  networking.useNetworkd = true;
  time.timeZone = "UTC";

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  users.users.root.openssh.authorizedKeys.keys =
    [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
    ];
  security.pki.certificates = [ (builtins.readFile ../../../../common/data/root_ca.crt) ];

  services.openssh.enable = true;

  system.stateVersion = "22.11";

}

