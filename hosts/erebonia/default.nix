{
  pkgs,
  config,
  lib,
  ...
}: let
  inherit (pkgs.mmell.lib.data.users.deployd) uid gid;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./hardware-configuration.nix
    (import ../../profiles/disko/btrfs.nix {
      disk = "/dev/sda";
      inherit lib;
    })
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
    runtimes = {
      allowed = ["kata" "runc"];
      default = "kata";
    };
    bridge = {
      name = "deploy-dmz";
      uplink = "uplink.100";
      subnet = "10.97.100.0/24";
      gateway = "10.97.100.1";
      poolStart = "10.97.100.128";
      poolEnd = "10.97.100.191";
    };
  };
  # Static UID — must match deployd-api UID in roer microVM for virtiofs socket access.
  users.users.deployd-helper.uid = uid;
  users.groups.deployd-helper.gid = gid;
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

  fluent-bit-agent.enable = true;
  node-exporter-client.enable = true;

  i18n.defaultLocale = "en_US.UTF-8";

  # NFS media share from liberl (NAS) — read-write
  fileSystems."/mnt/media" = {
    device = "liberl.internal:/export/rw/media";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "hard"
      "noatime"
      "rsize=1048576"
      "wsize=1048576"
      "timeo=600"
      "retrans=2"
      "nofail"
      "_netdev"
      "x-systemd.automount"
      "noauto"
      "x-systemd.idle-timeout=0"
    ];
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
