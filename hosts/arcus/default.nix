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

  networking.networkmanager = {
    enable = true;
    # Prevent NM from fighting systemd-networkd over the WireGuard interface
    unmanaged = ["wg-media"];
  };

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

  # SSH server required for deploy-rs remote deployments
  common.openssh.enable = true;

  # WireGuard tunnel for homelab service access.
  # NetworkManager manages WiFi (guest SSID); systemd-networkd manages the WG tunnel.
  # Use systemd.network.enable directly to avoid conflict with networking.useNetworkd
  # (which would try to manage all interfaces including WiFi).
  systemd.network = {
    enable = true;
    netdevs."30-wg-media" = {
      netdevConfig = {
        Name = "wg-media";
        Kind = "wireguard";
      };
      wireguardConfig = {
        PrivateKeyFile = config.sops.secrets."wg-media-privatekey".path;
      };
      wireguardPeers = [
        {
          PublicKey = "/CHzA3VNzlRoPJi8F3p2QVNIIxpmnjRdHRka7aj/BiY="; # Generated during setup
          AllowedIPs = [
            "10.100.20.0/24" # WG subnet
            "10.97.100.0/24" # DMZ subnet (Jellyfin, etc.)
            "10.97.11.0/24" # Management subnet (DNS resolution)
            "fdc6:55f2:0a5e:6414::/64"
            "fdc6:55f2:0a5e:64::/64"
            "fdc6:55f2:0a5e:b::/64"
          ];
          Endpoint = "10.97.30.1:51820"; # Router's untrusted VLAN gateway
          PersistentKeepalive = 25;
        }
      ];
    };
    networks."40-wg-media" = {
      matchConfig.Name = "wg-media";
      address = ["10.100.20.10/24" "fdc6:55f2:0a5e:6414::a/128"];
      routes = [
        {Destination = "10.97.100.0/24";} # DMZ
        {Destination = "10.97.11.0/24";} # Management (for DNS)
      ];
      dns = ["10.100.20.1"]; # Router DNS via WG tunnel
      domains = ["internal" "internal.mutantmell.net"];
    };
  };

  environment.systemPackages = with pkgs; [
    jellyfin-media-player # Jellyfin client
    moonlight-qt # Moonlight game streaming client (for future Sunshine host)
    clonehero # Guitar Hero clone (add to Steam via "Add a Non-Steam Game" once)
  ];

  system.stateVersion = "25.11";
}
