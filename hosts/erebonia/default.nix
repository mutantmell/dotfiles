{
  pkgs,
  config,
  ...
}: let
  deployUid = pkgs.mmell.lib.data.deployd.uid;
in {
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
  common.deployd.enable = true;
  deployd = {
    capabilityTokenFile = config.sops.secrets."deployd-capability-token".path;
    vsockHostSocket = "/var/lib/microvms/roer/notify.vsock_7000";
    vsockDirectoryService = "microvm@roer.service";
    caddy.listenAddress = (pkgs.mmell.lib.data.network.forHost "erebonia").host.ipv4;
    kata.enable = true;
    bridge = {
      name = "deploy-dmz";
      uplink = "eno1.100";
      subnet = "10.97.100.0/24";
      gateway = "10.97.100.1";
      poolStart = "10.97.100.128";
      poolEnd = "10.97.100.191";
    };
  };
  # Static UID — must match deployd-api UID in roer microVM for virtiofs socket access.
  users.users.deployd-helper.uid = deployUid;
  users.groups.deployd-helper.gid = deployUid;
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

  # Weekly auto-upgrade: update flake.lock, commit+push, then nixos-rebuild switch.
  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos";
    dates = "Sun *-*-* 04:00:00";
    allowReboot = true;
  };

  # Update flake.lock before nixos-upgrade runs, and push the result.
  systemd.services.nixos-upgrade-flake-update = {
    description = "Update flake.lock for auto-upgrade";
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/etc/nixos";
    };
    path = [pkgs.git pkgs.nix pkgs.openssh];
    script = ''
      nix flake update --commit-lock-file
      git push
    '';
  };
  systemd.services.nixos-upgrade = {
    wants = ["nixos-upgrade-flake-update.service"];
    after = ["nixos-upgrade-flake-update.service"];
  };

  system.stateVersion = "25.11";
}
