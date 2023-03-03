{ config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  nixpkgs.config.allowUnfree = true;
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.initrd.luks.devices = {
    root = {
      device = "/dev/sda3";
      preLVM = true;
    };
  };
  boot.loader.grub.device = "/dev/sda";
  networking.hostName = "svartalfheim";
  networking.networkmanager.enable = true;

  i18n = {
    defaultLocale = "en_US.UTF-8";
    inputMethod = {
      enabled = "fcitx";
      fcitx.engines = with pkgs.fcitx-engines; [ mozc ];
    };
  };

  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  fonts.fonts = with pkgs; [
    source-code-pro
    fira-code
    fira-mono
    fira-code-symbols
    freefont_ttf
    carlito
    dejavu_fonts
    ipafont
    kochi-substitute
    ttf_bitstream_vera
  ];

  fonts.fontconfig = {
    defaultFonts = {
      monospace = [
        "DejaVu Sans Mono"
        "IPAGothic"
      ];
      sansSerif = [
        "DejaVu Sans"
        "IPAPGothic"
      ];
      serif = [
        "DejaVu Serif"
        "IPAPMincho"
      ];
    };
  };

  time.timeZone = "America/Los_Angeles";

  environment.systemPackages = with pkgs; [
    vim
    home-manager
    gnome.adwaita-icon-theme
    gnomeExtensions.appindicator
  ];
  services.udev.packages = with pkgs; [ gnome.gnome-settings-daemon ];  

  services.printing.enable = true;

  sound.enable = true;
  hardware.pulseaudio = {
    enable = true;
    package = pkgs.pulseaudioFull;
    support32Bit = true;
  };

  hardware.opengl = {
    driSupport32Bit = true;
    extraPackages32 = with pkgs.pkgsi686Linux; [ libva ];
  };

  services.xserver.enable = true;
  services.xserver.layout = "us";

  services.xserver.libinput.enable = true;

  services.xserver.displayManager.gdm = {
    enable = true;
    wayland = false;
  };
  services.xserver.desktopManager.gnome = {
    enable = true;
  };
  services.xserver.displayManager.defaultSession = "gnome";

  programs.dconf.enable = true;

  users.users.mjollnir = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" "audio" ];
  };

  system.stateVersion = "22.11";

}
