{config, ...}: {
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "wg-media-privatekey" = {
        mode = "0440";
        group = "systemd-network";
      };
    };
  };
}
