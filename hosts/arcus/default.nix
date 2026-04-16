{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./disko.nix
    ./sops.nix
  ];

  networking.hostName = "arcus";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.networkmanager.enable = true;
  services.resolved.enable = true;

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
    autoUpdate = false; # hardwareupdater.py crash-loops without libhidapi; revisit later
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

  # SSH server required for deploy-rs remote deployments
  common.openssh.enable = true;

  # WireGuard tunnel for homelab service access.
  # wg-quick manages the tunnel independently of NetworkManager, so WiFi is unaffected.
  networking.wg-quick.interfaces.wg-media = {
    address = ["10.100.20.10/24" "fdc6:55f2:0a5e:6414::a/128"];
    privateKeyFile = config.sops.secrets."wg-media-privatekey".path;
    # DNS server + routing domains: tells systemd-resolved to send .internal
    # queries specifically through this interface rather than the default resolver.
    dns = ["10.100.20.1" "~internal" "~internal.mutantmell.net"];
    peers = [
      {
        publicKey = "/CHzA3VNzlRoPJi8F3p2QVNIIxpmnjRdHRka7aj/BiY=";
        allowedIPs = [
          "10.100.20.0/24" # WG subnet
          "10.97.100.0/24" # DMZ subnet (Jellyfin, etc.)
          "10.97.11.0/24" # Management subnet (DNS resolution)
          "fdc6:55f2:0a5e:6414::/64"
          "fdc6:55f2:0a5e:64::/64"
          "fdc6:55f2:0a5e:b::/64"
        ];
        endpoint = "10.97.30.1:51820"; # Router's untrusted VLAN gateway
        persistentKeepalive = 25;
      }
    ];
  };

  # Disable KDE screen lock — this is a gaming device, lock screen on resume is unwanted.
  # Placed in /etc/xdg/ as a system-wide default; user config in ~/.config/ would override.
  # TODO: migrate to home-manager nixosModule to manage mutantmell's KDE config directly,
  # which would be explicit and not overridable via the KDE settings UI.
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
  '';

  environment.systemPackages = with pkgs; [
    jellyfin-media-player # Jellyfin client
    moonlight-qt # Moonlight game streaming client (for future Sunshine host)
    clonehero # Guitar Hero clone (add to Steam via "Add a Non-Steam Game" once)
  ];

  system.stateVersion = "25.11";
}
