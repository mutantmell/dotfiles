{
  imports = [
    ./btrfs.nix
    ./deployd.nix
    ./firewall.nix
    ./fluent-bit.nix
    ./impermanence.nix
    ./incus.nix
    ./internal-pki.nix
    ./microvm.nix
    ./networking.nix
    ./openssh.nix
    ./ssh-cert-client.nix
  ];

  # Reserve 400-499 for project-static UIDs/GIDs (see lib/common/data/default.nix).
  # NixOS default SYS_UID_MIN/SYS_GID_MIN is 400; raising to 500 prevents
  # dynamic system user allocation from colliding with our registry.
  security.loginDefs.settings = {
    SYS_UID_MIN = 500;
    SYS_GID_MIN = 500;
  };
}
