{config, ...}: let
  persistDir = config.common.impermanence.persistDir;
in {
  common.impermanence.enable = true;

  environment.persistence.${persistDir} = {
    files = [
      "/etc/ssh/initrd_ssh_host_ed25519_key"
      "/etc/ssh/initrd_ssh_host_ed25519_key.pub"
    ];
  };

  common.zfs.impermanence = {
    enable = true;
    dataset = "zroot/local/root";
  };
}
