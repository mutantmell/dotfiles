{
  config,
  pkgs,
  ...
}: let
  hostname = "thebeyond";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host;
  inherit (net.hosts) phantasma;
in {
  imports = [
    ./hardware-configuration.nix
    (import ../../profiles/disko/tmpfs.nix {
      disk = "/dev/disk/by-id/nvme-KINGSTON_SNV3S500G_50026B7687893D29";
    })
    ./impermanence.nix
    ./sops.nix
    ./microvm
    ./router.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # update microcode to try and fix virtualization issues
  hardware.cpu.intel.updateMicrocode = true;

  # LUKS automatic unlock via keyfile on ESP.
  # systemd-cryptsetup-generator mounts the ESP, reads the keyfile, and unmounts it.
  boot.initrd.systemd.enable = true;
  boot.initrd.supportedFilesystems = ["vfat"];
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-partlabel/disk-main-persist";
    allowDiscards = true;
    keyFile = "/secrets/disk.key:/dev/disk/by-partlabel/disk-main-ESP";
    keyFileTimeout = 10;
  };

  # Ensure /boot/secrets directory exists
  system.activationScripts.createBootSecrets = ''
    mkdir -p /boot/secrets
    chmod 700 /boot/secrets
  '';

  networking.hostName = hostname;
  time.timeZone = "America/Los_Angeles";

  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    batctl
    git
    wireguard-tools
  ];

  common.openssh = {
    enable = true;
    keys = ["deploy" "home" "edith"];
  };

  networking.extraHosts =
    ''
      ${host.ipv4} thebeyond thebeyond.internal.mutantmell.net thebeyond.internal
      ${host.ipv6} thebeyond.internal.mutantmell.net thebeyond.internal
      ${phantasma.ipv4} phantasma phantasma.internal.mutantmell.net phantasma.internal
      ${phantasma.ipv6} phantasma.internal.mutantmell.net phantasma.internal
    ''
    + net.mkExtraHosts ["messeldam" "basel" "langport" "oracion" "trista"];

  fluent-bit-agent.enable = true;
  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
