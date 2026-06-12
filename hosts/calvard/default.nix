{
  pkgs,
  lib,
  ...
}: {
  nix.settings.experimental-features = ["nix-command" "flakes" "auto-allocate-uids" "uid-range"];
  imports = [
    ./hardware-configuration.nix
    (import ../../profiles/disko/btrfs.nix {
      disk = "/dev/nvme0n1";
      inherit lib;
    })
    ./microvm
    ./incus
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  common.impermanence.enable = true;
  common.btrfs.enable = true;
  common.btrfs.keyfileUnlock.enable = true;
  common.btrfs.impermanence.enable = true;

  boot.extraModprobeConfig = "options kvm_intel nested=1";

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
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
  '';

  # NFS media share from liberl (NAS) — read-only
  fileSystems."/mnt/media" = {
    device = "liberl.internal:/export/ro/media";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "hard"
      "ro"
      "noatime"
      "rsize=1048576"
      "timeo=600"
      "retrans=2"
      "nofail"
      "_netdev"
      "x-systemd.automount"
      "noauto"
      "x-systemd.idle-timeout=0"
    ];
  };

  environment.systemPackages = [
    pkgs.git
  ];
  security.polkit.enable = true;

  networking = {
    hostName = "calvard";
    useNetworkd = true;
    dhcpcd.enable = false;
  };

  common.internal-pki.enable = true;

  fluent-bit-agent.enable = true;
  node-exporter-client.enable = true;

  i18n.defaultLocale = "en_US.UTF-8";

  common.openssh = {
    enable = true;
    users = ["root"];
    keys = ["deploy" "home" "edith"];
  };

  programs.ssh.extraConfig = ''
    Host edith
      Hostname 10.97.21.42
      User root
      IdentityFile /etc/ssh/ssh_host_ed25519_key
      IdentitiesOnly yes
  '';

  users.mutableUsers = false;

  home-manager.users.root = {
    home.stateVersion = "25.11";
    programs.git = {
      enable = true;
      settings = {
        user.name = "mutantmell";
        user.email = "malaguy@gmail.com";
        core.sshCommand = "ssh -i /etc/ssh/ssh_host_ed25519_key";
      };
    };
  };

  system.stateVersion = "25.11";
}
