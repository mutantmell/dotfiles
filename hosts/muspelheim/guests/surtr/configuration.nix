{ config, pkgs, sops-nix, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      sops-nix.nixosModules.sops
      ./sops.nix
      ../../../../modules/overrides/wireguard.nix
    ];
  disabledModules =
    [ "services/networking/wireguard.nix"
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  environment.systemPackages = with pkgs; [
    home-manager
  ];

  networking.hostName = "surtr";
  networking.wireguard.interfaces = {
    # "wg0" = {
    #   ips = [ "10.100.0.1/24" ];
    #   privateKeyFile = config.sops.secrets."wireguard_private_key".path;
    #   peers = [
    #     {
    #       publicKey = "QdA39mQUqQjSvOTy4c+Zrtll1OEb/4vroewi2Zz6+Qs=";
    #       allowedIPs = [ "10.100.0.0/24" ];
    #       endpointFile = config.sops.secrets."wireguard_peer_address".path;
    #       dynamicEndpointRefreshSeconds = 15;
    #       persistentKeepalive = 25;
    #     }
    #   ];
    # };
    # "wg-mx" = {
    #   ips = [ "10.100.1.2/32" ];
    #   privateKeyFile = config.sops.secrets."wireguard_private_key".path;
    #   peers = [
    #     {
    #       publicKey = "hTmV7qOLXHCQnTWljCiNHf2P22GBd0n339Fcq4tVdlw=";
    #       allowedIPs = [ "10.100.1.0/24" ];
    #       endpoint = "helveticastandard.com:51895";
    #       persistentKeepalive = 25;
    #     }
    #   ];
    # };
  };

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

  services.openssh = {
    enable = true;
    passwordAuthentication = false;
    permitRootLogin = "prohibit-password";
    kbdInteractiveAuthentication = false;
  };

  system.stateVersion = "22.11";

}
