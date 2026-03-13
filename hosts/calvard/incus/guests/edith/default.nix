{
  pkgs,
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    ./sops.nix
  ];

  incus-guest = {
    profile = "dev";
    bridge = "br20";
  };

  nix.settings.experimental-features = ["nix-command" "flakes"];

  networking.hostName = "edith";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # Static network configuration (VLAN 20 / trusted, hostId 42)
  systemd.network.enable = true;
  services.resolved.enable = true;
  systemd.network.networks."50-enp5s0" = {
    matchConfig.Name = "enp5s0";
    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
    };
    address = [
      "10.97.20.42/24" # Primary
      "10.0.20.42/24" # Legacy (remove after migration)
      "fdc6:55f2:0a5e:14::2a/64"
    ];
    routes = [
      {Gateway = "10.97.20.1";}
      {Gateway = "fdc6:55f2:0a5e:14::1";}
    ];
    dns = ["10.97.20.1" "10.0.20.1" "fdc6:55f2:0a5e:14::1"];
  };

  environment.systemPackages = with pkgs; [
    home-manager
    git
    vim
    curl
    wget
  ];

  nix.settings = {
    allowed-users = ["@wheel"];
    trusted-users = ["root" "@wheel"];
  };

  time.timeZone = "UTC";

  users.users.mutantmell = {
    isNormalUser = true;
    extraGroups = ["wheel" "systemd-journal"];
    uid = 1000;
  };
  common.openssh = {
    enable = true;
    users = ["mutantmell" "root"];
    keys = ["home" "deploy" "calvard"];
    allowPassword = true;
  };

  # SSH host keys from host-side static directory (bind-mounted by incus)
  services.openssh.hostKeys = [
    {
      path = "/static/etc/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];

  boot.initrd.availableKernelModules = ["virtiofs"];
  fileSystems."/boot".options = ["fmask=0077" "dmask=0077"];

  # The /static virtiofs mount is hotplugged by Incus after the incus-agent
  # starts (not available at boot). The agent mounts it automatically at the
  # path configured in the Incus device config. We declare it here with nofail
  # so NixOS doesn't block boot waiting for it, and ensure sshd waits for it.
  fileSystems."/static" = {
    device = "incus_static";
    fsType = "virtiofs";
    options = ["nofail" "x-systemd.after=incus-agent.service"];
  };

  # Delay sshd until /static is mounted (host keys live there)
  systemd.services.sshd = {
    after = ["static.mount"];
    requires = ["static.mount"];
  };

  system.stateVersion = "25.11";
}
