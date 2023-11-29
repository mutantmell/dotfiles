{
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"

      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"

      "/root"  # Add for now, until we can get rid of the git repo in /root
    ];
    files = [
      "/etc/machine-id"

      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
      "/etc/ssh/initrd_ssh_host_ed25519_key"
      "/etc/ssh/initrd_ssh_host_ed25519_key.pub"
    ];
  };
  fileSystems."/persist".neededForBoot = true;
  common.zfs.impermanence = {
    enable = true;
    dataset = "zroot/local/root";
  };
}
