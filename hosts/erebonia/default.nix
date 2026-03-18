{pkgs, ...}: {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./hardware-configuration.nix
    (import ../../profiles/disko/btrfs.nix {disk = "/dev/sda";})
    ./sops.nix
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

  environment.systemPackages = [
    pkgs.git
  ];
  security.polkit.enable = true;

  networking = {
    hostName = "erebonia";
    useNetworkd = true;
    dhcpcd.enable = false;
  };

  networking.firewall.allowedTCPPorts = [9100];

  promtail-client.enable = true;

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = ["systemd"];
    port = 9100;
  };

  i18n.defaultLocale = "en_US.UTF-8";

  # NFS share from remiferia (NAS)
  fileSystems."/mnt/data" = {
    device = "remiferia.internal:/data/data";
    fsType = "nfs";
    options = ["x-systemd.automount" "noauto" "_netdev" "nfsvers=4" "soft" "timeo=150"];
  };

  users.mutableUsers = false;

  common.openssh = {
    enable = true;
    users = ["root"];
    keys = ["deploy" "home" "edith"];
  };

  programs.ssh.extraConfig = ''
    Host trista
      Hostname 10.97.100.51
      User root
      IdentityFile /etc/ssh/ssh_host_ed25519_key
      IdentitiesOnly yes
  '';

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
