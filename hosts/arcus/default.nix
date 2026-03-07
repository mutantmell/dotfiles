{
  config,
  pkgs,
  ...
}: {
  nixpkgs.config.allowUnfree = true;

  jovian = {
    steam = {
      enable = true;
      autoStart = true;
    };
    decky-loader.enable = true;
    devices.steamdeck = {
      enable = true;
      autoUpdate = true;
      enableGyroDsuService = true;
    };
  };

  programs.nix-ld = {
    enable = true;
    libraries = [pkgs.pciutils];
  };

  networking.hostName = "arcus";
  networking.networkmanager.enable = true;

  services.avahi = {
    enable = true;
    nssmdns = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  # Set state version to match when config was created (Oct 2023)
  system.stateVersion = "25.11";
}
