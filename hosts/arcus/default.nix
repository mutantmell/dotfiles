{
  config,
  pkgs,
  lib,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  wg = net.wireguardNetworks;
  myWg = wg."wg-media".hosts.arcus;
in {
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
    environment = {
      # Force Qt apps (Jellyfin, Moonlight) to use X11/xcb instead of Wayland.
      # Gamescope provides Xwayland for game windows but does not accept native
      # Wayland clients — Qt auto-detects WAYLAND_DISPLAY and tries to connect
      # as a Wayland client, which fails silently and causes Steam to kill the app.
      QT_QPA_PLATFORM = "xcb";
      # Disable Qt WebEngine's Chromium sandbox for jellyfin-media-player.
      # The sandbox requires kernel namespaces and seccomp filters that don't
      # work properly in gamescope's environment, causing slow startup (sandbox
      # setup stalls) and unclean exit (sandbox teardown fails). Security impact
      # is minimal — the content is a trusted local Jellyfin UI, not arbitrary web.
      QTWEBENGINE_DISABLE_SANDBOX = "1";
    };
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
    address = [myWg.iface4 myWg.iface6];
    privateKeyFile = config.sops.secrets."wg-media-privatekey".path;
    # No DNS config here — resolved's DefaultRoute behaviour causes wg-media to
    # intercept all queries when its DNS server is unreachable. .internal names
    # resolve fine via the untrusted VLAN DHCP DNS, which kresd handles.
    peers = [
      {
        publicKey = "/CHzA3VNzlRoPJi8F3p2QVNIIxpmnjRdHRka7aj/BiY=";
        allowedIPs = [
          wg."wg-media".subnet4
          net.networks.dmz.subnet4
          net.networks.management.subnet4
          wg."wg-media".subnet6
          net.networks.dmz.subnet6
          net.networks.management.subnet6
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
    (chromium.override {enableWideVine = true;}) # Browser with DRM for Netflix etc.
  ];

  system.stateVersion = "25.11";
}
