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
    (import ../../profiles/disko/tmpfs.nix {})
    ./impermanence.nix
    ./sops.nix
    ./microvm
    ./router.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # update microcode to try and fix virtualization issues
  hardware.cpu.intel.updateMicrocode = true;

  # LUKS automatic unlock: mount the ESP in initrd to access the keyfile,
  # then unmount so NixOS can mount it normally later.
  boot.initrd.supportedFilesystems = ["vfat"];
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-partlabel/disk-main-persist";
    allowDiscards = true;
    keyFile = "/boot/secrets/disk.key";
    preOpenCommands = ''
      mkdir -p /boot
      mount -t vfat /dev/disk/by-partlabel/disk-main-ESP /boot
    '';
    postOpenCommands = ''
      umount /boot
    '';
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
      ${host.ipv4} yggdrasil.internal
      ${phantasma.ipv4} phantasma phantasma.internal.mutantmell.net phantasma.internal
      ${phantasma.ipv6} phantasma.internal.mutantmell.net phantasma.internal
    ''
    + net.mkExtraHosts ["messeldam" "basel" "langport" "oracion" "trista"];

  promtail-client.enable = true;

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd"];
    port = 9100;
    listenAddress = host.ipv4; # Bind to INFRA interface only
  };

  system.stateVersion = "25.11";
}
