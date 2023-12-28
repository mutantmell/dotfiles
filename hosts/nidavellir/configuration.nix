{ config, pkgs, lib, ... }:

{
  imports = [
    ./sops.nix
    ./home-assistant.nix
  ];

  boot = {
    kernelPackages = pkgs.linuxKernel.packages.linux_rpi4;
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
  };

  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    MaxFileSec=7day
    Storage=volatile
  '';

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };

  networking = {
    hostName = "nidavellir";
    wireless = {
      enable = true;
      environmentFile = config.sops.secrets."wpa.env".path;
      networks."@wpa_key@" = {
        psk = "@wpa_psk@";
        authProtocols = [ "WPA-PSK-SHA256" ];
        extraConfig = ''
          ieee80211w=2
        '';
      };
      interfaces = [ "wlan0" ];
    };
    useDHCP = false;
    defaultGateway.address = "10.1.20.1";
    defaultGateway.interface = "wlan0";
    nameservers = [ "10.1.20.1" ];
    # TODO: bond these together, once the ip addr space for wifi and ethernet are unified
    interfaces.wlan0 = {
      useDHCP = false;
      ipv4.addresses = [{
        address = "10.1.20.50";
        prefixLength = 24;
      }];
    };
    interfaces.end0 = {
      useDHCP = false;
    #  ipv4.addresses = [{
    #    address = "10.0.20.50";
    #    prefixLength = 24;
    #  }];
    };
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  environment.systemPackages = with pkgs; [ vim ];

  common.openssh.enable = true;

  hardware.enableRedistributableFirmware = true;
  system.stateVersion = "23.11";
}
