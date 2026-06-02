{config, ...}: {
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    # NOTE: If this fails, it's because the key hasn't been pushed yet.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "wg-media-privatekey" = {};
    };
  };
}
