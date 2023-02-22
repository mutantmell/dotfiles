{ config, pkgs, sops-nix, ... }:

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
      sops-nix.nixosModules.sops
      ./sops.nix
      ../../../../modules/overrides/wireguard.nix

      ./proxy.nix
      ./wireguard.nix
    ];
  disabledModules =
    [ "services/networking/wireguard.nix"
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  environment.systemPackages = with pkgs; [
    home-manager
    git
  ];

  networking.hostName = "surtr";
  networking.interfaces."ens3" = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "10.0.100.40";
      prefixLength = 24;
    }];
  };
  networking.defaultGateway = "10.0.100.1";
  networking.nameservers = [ "10.0.100.1" ];

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

  services.openssh = {
    enable = true;
    passwordAuthentication = false;
    permitRootLogin = "prohibit-password";
    kbdInteractiveAuthentication = false;
  };

  system.stateVersion = "22.11";

}
