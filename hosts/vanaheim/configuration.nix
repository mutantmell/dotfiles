# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelModules = [ "kvm-intel" ];
  
  environment.systemPackages = with pkgs; [
    virtmanager
  ];

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      ovmf.enable = true;
      runAsRoot = false;
    };
    onBoot = "start";
    onShutdown = "suspend";
    allowedBridges = [ "br20" "br100" ];
  };
  security.polkit.enable = true;

  networking = let lan = "enp88s0"; in {
    hostName = "vanaheim";
    dhcpcd.enable = false;
  
    vlans = {
      "${lan}.10" = { id = 10; interface = lan; };
      "${lan}.20" = { id = 20; interface = lan; };
      "${lan}.100" = { id = 100; interface = lan; };
    };
  
    bridges = {
      "br20".interfaces = [ "${lan}.20" ];
      "br100".interfaces = [ "${lan}.100" ];
    };
  
  
    interfaces = {
      "${lan}.10" = {
        useDHCP = false;
        ipv4.addresses = [{
          address = "10.0.10.30";
          prefixLength = 24;
        }];
      };
    };
    defaultGateway = "10.0.10.1";
    nameservers = [ "10.0.10.1" ]; 
  };

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  # time.timeZone = "Europe/Amsterdam";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkbOptions in tty.
  # };

  # Enable the X11 windowing system.
  # services.xserver.enable = true;

  # Configure keymap in X11
  # services.xserver.layout = "us";
  # services.xserver.xkbOptions = {
  #   "eurosign:e";
  #   "caps:escape" # map caps to escape.
  # };

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # sound.enable = true;
  # hardware.pulseaudio.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users = let
    keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
    ];
  in {
    root.openssh.authorizedKeys.keys = keys;
    "qemu-agent" = {
      isNormalUser = true;
      extraGroups = [ "libvirtd" ];
      openssh.authorizedKeys.keys = keys;
    };
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  services.openssh.forwardX11 = true;
  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?

}

