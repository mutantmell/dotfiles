{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
  ];

  networking.hostName = "angbar";

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = ["mem_sleep_default=deep"]; # reliable S3 sleep on Gen 7

  # Networking
  networking.networkmanager.enable = true;

  # Locale
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Nix
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel"];
  };

  # User
  users.users.mutantmell = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager" "video" "audio"];
    uid = 1000;
  };

  # Home-manager (mutantmell profile managed standalone via homeConfigurations."mutantmell@angbar")
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.root = {
      home.stateVersion = "25.11";
      programs.git = {
        enable = true;
        settings = {
          user.name = "mutantmell";
          user.email = "malaguy@gmail.com";
        };
      };
    };
  };

  # SSH
  common.ssh-cert-client.enable = true;

  # Desktop
  programs.sway.enable = true;
  xdg.portal = {
    enable = true;
    wlr.enable = true;
  };
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd sway";
      user = "greeter";
    };
  };

  # Power management
  services.thermald.enable = true;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "performance";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
    };
  };

  # Audio
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # Bluetooth
  hardware.bluetooth.enable = true;

  # Firmware updates
  services.fwupd.enable = true;

  # Fonts
  fonts.packages = [pkgs.jetbrains-mono];

  # Session-resilient connection to edith
  environment.systemPackages = [pkgs.eternal-terminal pkgs.home-manager];
  environment.variables.ET_NO_TELEMETRY = "1";

  system.stateVersion = "25.11";
}
