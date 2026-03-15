{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./sops.nix
    ./home-assistant.nix
    ./modules/mqtt.nix
  ];

  boot = {
    kernelPackages = pkgs.linuxKernel.packages.linux_rpi4;
    initrd.availableKernelModules = ["xhci_pci" "usbhid" "usb_storage"];
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
      options = ["noatime"];
    };
  };

  networking = {
    hostName = "azoth";
    wireless = {
      enable = true;
      environmentFile = config.sops.secrets."wpa.env".path;
      networks."@wpa_key@" = {
        psk = "@wpa_psk@";
        authProtocols = ["WPA-PSK-SHA256"];
        extraConfig = ''
          ieee80211w=2
        '';
      };
      interfaces = ["wlan0"];
    };
    useDHCP = false;
    defaultGateway.address = "10.97.20.1";
    defaultGateway.interface = "bond0";
    nameservers = ["10.97.20.1"];
    bonds.bond0 = {
      interfaces = ["wlan0" "end0"];
      driverOptions = {
        mode = "active-backup";
        primary = "wlan0";
        fail_over_mac = "active";
        miimon = "100";
      };
    };
    interfaces.bond0 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "10.97.20.50";
          prefixLength = 24;
        }
      ];
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

  environment.systemPackages = with pkgs; [vim];

  common.openssh = {
    enable = true;
    keys = ["deploy" "edith"];
  };

  hardware.enableRedistributableFirmware = true;
  system.stateVersion = "25.11";
}
