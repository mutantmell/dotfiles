{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./disko.nix
  ];

  networking.hostName = "arcus";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.networkmanager.enable = true;

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel"];
  };

  users.users.mutantmell = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager" "video" "audio"];
    uid = 1000;
  };

  # Gaming mode (boots directly into Steam Big Picture via gamescope-session)
  jovian.steam = {
    enable = true;
    autoStart = true;
    user = "mutantmell";
    desktopSession = "plasma"; # used when switching to Desktop Mode
  };

  # Steam Deck hardware: kernel, firmware, TDP control, fan curve, vendor drivers
  jovian.devices.steamdeck = {
    enable = true;
    autoUpdate = true;
    enableVendorDrivers = true;
  };

  # Decky Loader plugin support
  jovian.decky-loader.enable = true;

  # udev rules for Steam hardware (controllers, index, etc.)
  hardware.steam-hardware.enable = true;

  # Desktop environment for "Switch to Desktop" mode
  # KDE Plasma mirrors the SteamOS desktop experience most closely
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  # Audio
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Bluetooth (controllers, wireless audio, accessories)
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  services.blueman.enable = true;

  # Compressed swap — helps when gaming workloads push memory limits
  zramSwap.enable = true;

  system.stateVersion = "25.11";
}
