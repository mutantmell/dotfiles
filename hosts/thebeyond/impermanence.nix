{
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"

      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
    ];
    files = [
      "/etc/machine-id"

      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"

      "/root/.ssh/known_hosts"
    ];
  };
  fileSystems."/persist".neededForBoot = true;

  # Bind mount /nix onto the persistent ext4 partition so the Nix store
  # doesn't land on the 2G tmpfs root (which causes "No space left on device").
  fileSystems."/nix" = {
    device = "/persist/nix";
    fsType = "none";
    options = [ "bind" ];
    neededForBoot = true;
  };
}
