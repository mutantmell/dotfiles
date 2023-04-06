{ config, pkgs, sops-nix, ... }:

let
  dataDir = "/mnt/nas";
in {
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      sops-nix.nixosModules.sops
      ./sops.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "njord";

  networking.nftables.enable = true;
  networking.firewall.interfaces."ens3" = {
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ 5353 ];
  };
  networking.useNetworkd = true;
  networking.interfaces."ens3" = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "10.0.100.51";
      prefixLength = 24;
    }];
  };
  networking.defaultGateway = "10.0.100.1";
  networking.nameservers = [ "10.0.100.1" ];

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

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.openFirewall = false;

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
      openssh.authorizedKeys.keys =
        [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJl4UkXB94b0e/4YrPXIT4J4l73/mCwh724Yr1VFy7dk malaguy@gmail.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE5AN0gzpx+1bJNZbGfLt4m2kD59WYmyqgIkXmzYbL+Q malaguy@gmail.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINZ7mLwJ54FpGVAEdqB04CYUi3QH8ZIr3gsDhj220/d+ malaguy@gmail.com"
        ] ++ keys;
      extraGroups = [ "git" ];
    };
  };
  users.groups.git.gid = 1000;

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

  services.avahi = {
    enable = true;
    openFirewall = false;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  system.stateVersion = "22.11";
}
