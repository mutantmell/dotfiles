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
      "/etc/ssh/initrd_ssh_host_ed25519_key"
      "/etc/ssh/initrd_ssh_host_ed25519_key.pub"

      "/root/.ssh/known_hosts"
    ];
  };
  fileSystems."/persist".neededForBoot = true;
  common.zfs.impermanence = {
    enable = true;
    dataset = "zroot/local/root";
  };
}
